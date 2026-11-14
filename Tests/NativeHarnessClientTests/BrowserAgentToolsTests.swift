import Foundation
import JavaScriptCore
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A CDP connection that answers from a script and records what was sent.
@MainActor
final class ScriptedCDP: BrowserAgentCDP {
    var sent: [(method: String, params: [String: JSONValue])] = []
    var eventLog: [(method: String, params: JSONValue)] = []
    var mainFrameID: String?
    var responders: [String: @MainActor ([String: JSONValue]) throws -> JSONValue] = [:]
    /// Events that arrive once a method has been sent.
    var eventsAfter: [String: [(method: String, params: JSONValue)]] = [:]
    /// Methods whose answer does not come until `resumeSuspended()`, like a page paused on a dialog.
    var suspendOn: Set<String> = []
    private var suspended: [CheckedContinuation<Void, Never>] = []

    func resumeSuspended() {
        let waiting = suspended
        suspended = []
        waiting.forEach { $0.resume() }
    }
    var pageURL = "https://example.com/"
    var pageTitle = "Example Domain"
    var bodyTexts: [String] = [""]
    var pixelRatio: Double = 1

    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        sent.append((method, params))
        eventLog += eventsAfter[method] ?? []
        if suspendOn.contains(method) {
            await withCheckedContinuation { suspended.append($0) }
        }
        if let responder = responders[method] { return try responder(params) }
        // The vault's look for elements that show a filled value (`vaultSecretNodes`): this page has none.
        if method == "Runtime.evaluate", params["objectGroup"] != nil {
            return .object(["result": .object(["type": .string("object"), "objectId": .string("none-shown")])])
        }
        if method == "Runtime.getProperties" { return .object(["result": .array([])]) }
        if method == "Runtime.evaluate", let expression = params["expression"]?.stringValue {
            if expression.contains("location.href") {
                return Self.value(.array([.string(pageURL), .string(pageTitle)]
                    + (expression.contains("readyState") ? [.string("complete")] : [])))
            }
            if expression == "devicePixelRatio" { return Self.value(.number(pixelRatio)) }
            if expression.contains("innerText") {
                let text = bodyTexts.count > 1 ? bodyTexts.removeFirst() : bodyTexts.first ?? ""
                return Self.value(.string(text))
            }
            if expression.contains("scrollX") {
                return Self.value(.array([.integer(0), .integer(400), .integer(1280), .integer(5000)]))
            }
        }
        return .object([:])
    }

    var methods: [String] { sent.map(\.method) }

    func params(of method: String) -> [[String: JSONValue]] {
        sent.filter { $0.method == method }.map(\.params)
    }

    static func value(_ value: JSONValue) -> JSONValue {
        .object(["result": .object(["type": .string("object"), "value": value])])
    }

    static func missingNode(_ method: String) -> BrowserDevToolsError {
        .protocolError(method, .object(["code": .integer(-32000), "message": .string("No node with given id found")]))
    }
}

@MainActor
final class BrowserAgentToolsTests: XCTestCase {
    private var cdp: ScriptedCDP!
    private var page: BrowserAgentPage!
    private var tools: BrowserAgentTools!

    /// Host commands the page sent (dialog and file chooser answers).
    private var hostCommands: [BrowserHostCommand] = []
    /// The files outside the task's folders the tools asked about, and the answer they get.
    private var askedFiles: [String] = []
    private var allowsFiles = false

    override func setUp() async throws {
        cdp = ScriptedCDP()
        hostCommands = []
        page = BrowserAgentPage(cdp: cdp, tabID: 4) { [unowned self] in self.hostCommands.append($0) }
        let page = page!
        tools = BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in page })
        tools.pollInterval = .milliseconds(5)
        tools.fileChooserWait = .milliseconds(20)
    }

    private func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
        await tools.run(tool: tool, arguments: .object(arguments), sessionID: UUID())
    }

    /// The references a snapshot gave, in the order it shows them.
    private static func refs(in text: String) -> [String] {
        text.matches(of: #/\[ref=(@e\d+)\]/#).map { String($0.1) }
    }

    /// The page from the snapshot test: a heading, a text field, a button, a paragraph, a link.
    private func loadSnapshot() async -> AgentToolResult {
        func node(_ id: String, _ role: String, _ name: String = "", children: [String] = [], backend: Int64? = nil,
                  properties: [(String, JSONValue)] = [], value: String? = nil, ignored: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "ignored": .bool(ignored),
                "role": .object(["type": .string("role"), "value": .string(role)]),
                "name": .object(["type": .string("computedString"), "value": .string(name)]),
                "childIds": .array(children.map { .string($0) }),
                "properties": .array(properties.map { .object(["name": .string($0.0), "value": .object(["value": $0.1])]) })
            ]
            if id != "1" { fields["parentId"] = .string("1") }
            if let backend { fields["backendDOMNodeId"] = .integer(backend) }
            if let value { fields["value"] = .object(["type": .string("string"), "value": .string(value)]) }
            return .object(fields)
        }
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                node("1", "RootWebArea", "Example Domain", children: ["2", "3", "7", "9", "10"], backend: 1,
                     properties: [("url", .string("https://example.com/"))]),
                node("2", "heading", "Welcome", children: ["2a"], backend: 10, properties: [("level", .integer(1))]),
                node("2a", "StaticText", "Welcome", backend: 20),
                node("3", "generic", children: ["4", "5"], backend: 11),
                node("4", "textbox", "Name", backend: 12, properties: [("focusable", .bool(true)), ("required", .bool(true))], value: "Ada"),
                node("5", "button", "Send", children: ["6"], backend: 13),
                node("6", "StaticText", "Send", backend: 21),
                node("7", "paragraph", children: ["8"], backend: 14),
                node("8", "StaticText", "Hello   world", backend: 22),
                node("9", "link", "Docs", backend: 15, properties: [("url", .string("https://example.com/docs"))]),
                node("10", "none", "hidden", ignored: true)
            ])])
        }
        return await run(AgentToolCatalog.snapshot)
    }

    // MARK: - Navigate

    func testNavigateLoadsTheAddressAndWaitsForTheLoadEvent() async {
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F"), "loaderId": .string("L")]) }
        cdp.eventsAfter["Page.navigate"] = [("Page.loadEventFired", .object(["timestamp": .number(1)]))]
        let result = await run(AgentToolCatalog.navigate, ["url": .string("example.com")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Loaded https://example.com/\nTitle: Example Domain")
        XCTAssertEqual(Array(cdp.methods.prefix(5)),
                       ["Page.enable", "Runtime.enable", "Log.enable", "Page.getFrameTree", "Page.navigate"])
        XCTAssertEqual(cdp.params(of: "Page.navigate").first?["url"], .string("https://example.com"))
    }

    func testNavigateReportsAFailedLoadAndRefusesAddressesOutsideThePolicy() async {
        cdp.responders["Page.getFrameTree"] = { _ in .object(["frameTree": .object(["frame": .object(["id": .string("F")])])]) }
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F"), "errorText": .string("net::ERR_NAME_NOT_RESOLVED")]) }
        let failed = await run(AgentToolCatalog.navigate, ["url": .string("https://nowhere.invalid")])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("net::ERR_NAME_NOT_RESOLVED"), failed.text)

        for refused in ["javascript:alert(1)", "chrome://settings", "ftp://example.com/file"] {
            let result = await run(AgentToolCatalog.navigate, ["url": .string(refused)])
            XCTAssertTrue(result.isError, refused)
        }
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 1,
                       "The panel's address rule applies before anything reaches the browser")
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        _ = await run(AgentToolCatalog.navigate, ["url": .string("localhost:3000/app")])
        XCTAssertEqual(cdp.params(of: "Page.navigate").last?["url"], .string("http://localhost:3000/app"))

        // Chromium answers only once the navigation can commit or has ended. Without an answer, the error says what
        // the tab shows, from the browser's own history, and that the navigation Chromium started there goes on.
        cdp.eventLog += [("Page.frameNavigated", .object(["frame": .object(["id": .string("F"), "url": .string("https://example.com/")])])),
                         ("Page.loadEventFired", .object([:]))]
        cdp.responders["Page.getNavigationHistory"] = { _ in
            .object(["currentIndex": .integer(1), "entries": .array([
                .object(["url": .string("about:blank"), "title": .string("")]),
                .object(["url": .string("https://example.com/"), "title": .string("Example Domain")])
            ])])
        }
        cdp.responders["Page.navigate"] = { _ in throw BrowserDevToolsError.timedOut("Page.navigate") }
        cdp.eventsAfter["Page.navigate"] = [
            ("Page.frameStartedNavigating", .object(["frameId": .string("F"), "url": .string("https://example.com/next"),
                                                     "navigationType": .string("differentDocument")])),
            ("Page.frameStartedLoading", .object(["frameId": .string("F")]))
        ]
        let late = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com/next")])
        XCTAssertEqual(late.failure?.kind, .timedOut)
        XCTAssertTrue(late.text.hasPrefix("The browser did not answer Page.navigate to https://example.com/next within 30 "
            + "seconds. Chromium answers once the response is in"), late.text)
        XCTAssertTrue(late.text.contains("\nThe tab shows https://example.com/ (“Example Domain”), loaded.\nChromium is still "
            + "navigating the tab to https://example.com/next, and shows that page if its response comes. From the moment "
            + "the request goes out until the navigation ends, Chromium holds calls to the page"), late.text)
        // Where the host says whether the request went out, the error says which Chromium waits on.
        page.requestSent = { true }
        let sent = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com/next")])
        XCTAssertTrue(sent.text.contains("https://example.com/next, and shows that page if its response comes. Its request "
            + "went out and no response has come."), sent.text)
        page.requestSent = { false }
        let unloading = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com/next")])
        XCTAssertTrue(unloading.text.contains("It has not sent the request yet: the beforeunload handlers of the page's "
            + "frames have not all returned"), unloading.text)
        // A frame's own navigation is not the tab's, and one that stopped without a commit goes on no longer.
        cdp.eventLog.append(("Page.frameStartedNavigating", .object(["frameId": .string("child"), "url": .string("https://ads.test/")])))
        XCTAssertEqual(page.pendingNavigation(), "https://example.com/next")
        cdp.eventLog.append(("Page.frameStoppedLoading", .object(["frameId": .string("F")])))
        XCTAssertNil(page.pendingNavigation())
    }

    /// A file outside the task's folders, read after `..`, escapes and symbolic links, opens only when the app
    /// says so: at once for a task that runs without asking, on the person's answer otherwise
    /// (`AppModel.allowsBrowserFile`). A file the page brings in itself (a link, a script, an iframe) is asked
    /// about before the next tool reads the page, and one the task was let open is not asked about again.
    func testAFileOutsideTheTasksFoldersOpensOnlyWhenAllowed() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "agent-files-\(UUID().uuidString)")
        let root = base.appending(path: "work"), secret = base.appending(path: "secret")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data("<p>hi</p>".utf8).write(to: root.appending(path: "page.html"))
        try Data("key".utf8).write(to: secret.appending(path: "key.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: secret)
        defer { try? FileManager.default.removeItem(at: base) }
        tools.workspaceRoots = { _ in [root] }
        tools.allowsFileOutsideFolders = { [unowned self] _, path in
            askedFiles.append(path)
            return allowsFiles
        }
        let task = UUID()
        func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), sessionID: task)
        }
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        let rootPath = root.path(percentEncoded: false)
        let key = secret.appending(path: "key.txt").resolvingSymlinksInPath().path(percentEncoded: false)
        // What the tab is told the agent opened, for a remote device (`BrowserTab.noteAgentOpened`).
        var agentOpened: [String] = []
        page.agentOpens = { agentOpened.append($0) }

        let inside = await run(AgentToolCatalog.navigate, ["url": .string(root.appending(path: "page.html").absoluteString)])
        XCTAssertFalse(inside.isError, inside.text)
        XCTAssertTrue(askedFiles.isEmpty, "A file in the task's folders opens without asking")

        for escape in [rootPath + "/../secret/key.txt", root.appending(path: "link/key.txt").absoluteString,
                       "file://" + rootPath + "/%2e%2e/secret/key.txt", "file://" + rootPath + "/..\\secret/key.txt"] {
            let refused = await run(AgentToolCatalog.navigate, ["url": .string(escape)])
            XCTAssertEqual(refused.text, "The person did not allow opening \(key).", escape)
        }
        XCTAssertEqual(askedFiles, [key, key, key, key])
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 1, "A refused file is not opened")

        allowsFiles = true
        let allowed = await run(AgentToolCatalog.navigate, ["url": .string(root.appending(path: "link/key.txt").absoluteString)])
        XCTAssertFalse(allowed.isError, allowed.text)
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 2)
        XCTAssertEqual(agentOpened, [root.appending(path: "page.html").absoluteString, root.appending(path: "link/key.txt").absoluteString],
                       "only the files it opened, a refused one not")
        // The page shows that file now; reading it asks no more.
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("F"), "url": .string("file://" + key)])])))
        let console = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(console.isError, console.text)
        XCTAssertEqual(askedFiles.count, 5)

        allowsFiles = false
        let other = secret.resolvingSymlinksInPath().appending(path: "other.txt").path(percentEncoded: false)
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object([
            "id": .string("C"), "parentId": .string("F"), "url": .string(URL(filePath: other).absoluteString)
        ])])))
        let read = await run(AgentToolCatalog.snapshot)
        XCTAssertEqual(read.text, "The page shows \(other), a file outside this task's folders, and the person did not allow opening it.")
        XCTAssertFalse(cdp.methods.contains("Accessibility.getFullAXTree"), "Nothing of the page is read")
        XCTAssertEqual(askedFiles.last, other)

        // Once the page moves on, its files go with it.
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("F"), "url": .string("https://example.com/")])])))
        let moved = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(moved.isError, moved.text)
        XCTAssertEqual(askedFiles.count, 6)
        XCTAssertNil(BrowserAgentWorkspaceFile.realPath(ofFileAddress: "https://example.com/"))
    }

    /// The host checks every navigation, the agent's included, and says so with an event.
    func testANavigationTheHostBlocksIsAnErrorAndAPageLedOneIsANotice() async {
        let page = page!
        cdp.responders["Page.navigate"] = { params in
            page.receive(.navigationBlocked(tab: 4, url: params["url"]?.stringValue ?? ""))
            return .object(["frameId": .string("F"), "errorText": .string("net::ERR_ABORTED")])
        }
        let blocked = await run(AgentToolCatalog.navigate, ["url": .string("data:text/html,hi")])
        XCTAssertTrue(blocked.isError)
        XCTAssertEqual(blocked.text, "The browser's address policy blocked data:text/html,hi.")

        cdp.responders["Input.dispatchMouseEvent"] = { params in
            if params["type"] == .string("mouseReleased") { page.receive(.navigationBlocked(tab: 4, url: "chrome://settings")) }
            return .object([:])
        }
        let clicked = await run(AgentToolCatalog.click, ["x": .number(1), "y": .number(1)])
        XCTAssertFalse(clicked.isError)
        XCTAssertTrue(clicked.text.contains("The page tried to open chrome://settings, which the browser's address policy blocks."),
                      clicked.text)

        // A refusal that arrives after the tool answered is named by the next result, once.
        page.receive(.navigationBlocked(tab: 4, url: "ftp://example.com/late"))
        let next = await run(AgentToolCatalog.consoleMessages)
        XCTAssertTrue(next.text.contains("ftp://example.com/late"), next.text)
        let after = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(after.text.contains("ftp://example.com/late"), after.text)
    }

    // MARK: - Dialogs and file choosers

    private func dialog(_ kind: BrowserJavaScriptDialog.Kind, _ message: String, id: Int = 3) -> BrowserHostEvent {
        .javaScriptDialog(tab: 4, dialog: BrowserJavaScriptDialog(
            id: id, kind: kind, message: message, defaultPrompt: kind == .prompt ? "Ada" : "",
            origin: "https://example.com", isReload: false
        ))
    }

    func testADialogThatOpensDuringAToolEndsItsWaitAndPausesTheOtherTools() async throws {
        cdp.suspendOn = ["Runtime.evaluate"]
        let running = Task { await run(AgentToolCatalog.evaluate, ["function": .string("() => confirm('Delete?')")]) }
        try await Task.sleep(for: .milliseconds(30))
        page.receive(dialog(.confirm, "Delete?"))
        let interrupted = await running.value
        XCTAssertFalse(interrupted.isError)
        XCTAssertEqual(interrupted.text, "A JavaScript confirm dialog from https://example.com is open: “Delete?”. It "
            + "opened during browser_evaluate. The page is paused until you answer it with browser_handle_dialog.")

        let refused = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("answer it with browser_handle_dialog"), refused.text)
        let console = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(console.isError, "Reading the console needs no page")
        XCTAssertTrue(console.text.contains("confirm dialog"), "Every result says a dialog is open")

        let answered = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertEqual(answered.text, "Dismissed the confirm dialog “Delete?”.")
        XCTAssertEqual(hostCommands.last, .javaScriptDialogResult(tab: 4, dialog: 3, accepted: false, text: nil))
        let none = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(none.isError)
        cdp.resumeSuspended()
    }

    func testAPromptTakesTextAndADialogTheHostWithdrawsIsForgotten() async {
        page.receive(dialog(.prompt, "Your name?", id: 9))
        let answered = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true), "promptText": .string("Grace")])
        XCTAssertEqual(answered.text, "Accepted the prompt dialog “Your name?”.")
        XCTAssertEqual(hostCommands.last, .javaScriptDialogResult(tab: 4, dialog: 9, accepted: true, text: "Grace"))

        page.receive(dialog(.beforeUnload, "Leave site?", id: 10))
        page.receive(.javaScriptDialogReset(tab: 4))
        let afterReset = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(afterReset.text.contains("dialog"), afterReset.text)

        // A permission request pauses nothing; the agent can close it but never allow it.
        let commands = hostCommands.count
        page.receive(.permissionPrompt(tab: 4, prompt: BrowserPermissionPrompt(
            id: 12, origin: "https://example.com", permissions: ["notifications"]
        )))
        let clicked = await run(AgentToolCatalog.click, ["x": .number(1), "y": .number(1)])
        XCTAssertFalse(clicked.isError, clicked.text)
        XCTAssertTrue(clicked.text.contains("asks permission for notifications"), clicked.text)
        let allowed = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(allowed.isError, allowed.text)
        XCTAssertEqual(hostCommands.count, commands, "The agent's accept answers nothing")
        let closed = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertFalse(closed.isError, closed.text)
        XCTAssertEqual(hostCommands.last, .permissionResult(tab: 4, prompt: 12, result: .dismiss))
        let afterClose = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(afterClose.text.contains("asks permission"), afterClose.text)
    }

    func testABatchStopsWithoutErrorWhenADialogOpens() async throws {
        cdp.responders["Input.dispatchMouseEvent"] = { [unowned self] params in
            if params["type"] == .string("mouseReleased") { self.page.receive(self.dialog(.alert, "Saved")) }
            return .object([:])
        }
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_click"), "input": .object(["x": .number(1), "y": .number(1)])]),
            .object(["name": .string("browser_snapshot")])
        ])])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("alert dialog from https://example.com is open: “Saved”"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Stopped after action 1 because a dialog is open; 1 later action was not run."),
                      result.text)
    }

    func testFileUploadsComeOnlyFromTheTasksFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appending(path: "agent-outside-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "docs/a.txt"))
        try Data("b".utf8).write(to: root.appending(path: "b.txt"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape.txt"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        tools.workspaceRoots = { _ in [root] }

        let noChooser = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("b.txt")])])
        XCTAssertTrue(noChooser.isError)
        XCTAssertTrue(noChooser.text.contains("No file chooser is open in tab 4"), noChooser.text)

        page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 5, mode: .open, title: "Upload", defaultPath: "", extensions: [])))
        let notice = await run(AgentToolCatalog.consoleMessages)
        XCTAssertTrue(notice.text.contains("A file chooser “Upload” is open"), notice.text)
        // A failed tool says what the page waits on too.
        let noDialog = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(noDialog.isError)
        XCTAssertTrue(noDialog.text.contains("A file chooser “Upload” is open"), noDialog.text)
        for refused in [outside.path(percentEncoded: false), "escape.txt", "../\(outside.lastPathComponent)", "docs", "missing.txt"] {
            let result = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string(refused)])])
            XCTAssertTrue(result.isError, refused)
        }
        let two = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("b.txt"), .string("docs/a.txt")])])
        XCTAssertTrue(two.text.contains("takes one file"), two.text)
        XCTAssertTrue(hostCommands.isEmpty, "Nothing outside the rules reaches the page")

        let uploads = root.appending(path: "uploads")
        tools.uploadFolder = uploads
        let chosen = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("docs/a.txt")])])
        XCTAssertEqual(chosen.text, "Gave the file chooser “a.txt”.")
        // The page gets a copy read from the checked path, which a later swap of the file cannot change.
        guard case .fileDialogResult(tab: 4, dialog: 5, paths: let paths?)? = hostCommands.last, paths.count == 1,
              let copy = paths.first else {
            return XCTFail("\(String(describing: hostCommands.last))")
        }
        XCTAssertTrue(copy.hasPrefix(uploads.path(percentEncoded: false)), copy)
        XCTAssertEqual(URL(filePath: copy).lastPathComponent, "a.txt")
        try FileManager.default.removeItem(at: root.appending(path: "docs/a.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "docs/a.txt"), withDestinationURL: outside)
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "a")
        XCTAssertThrowsError(try BrowserAgentWorkspaceFile.privateCopy(
            of: root.appending(path: "docs/a.txt").path(percentEncoded: false), roots: [root], in: uploads),
            "A link swapped in after the check is not followed out of the task's folders")
        let fifo = root.appending(path: "docs/pipe").path(percentEncoded: false)
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertThrowsError(try BrowserAgentWorkspaceFile.privateCopy(of: fifo, roots: [root], in: uploads),
                             "A pipe is refused without waiting for a writer")

        // A folder goes as its path, so one that holds a link out of the task's folders does not go; a link
        // that stays inside them does.
        try FileManager.default.createDirectory(at: root.appending(path: "site/assets"), withIntermediateDirectories: true)
        try Data("page".utf8).write(to: root.appending(path: "site/index.html"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "site/assets/b.txt"),
                                                   withDestinationURL: root.appending(path: "b.txt"))
        page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 6, mode: .openFolder, title: "Upload a folder",
                                                                   defaultPath: "", extensions: [])))
        let sent = hostCommands.count
        let folder = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("site")])])
        XCTAssertEqual(folder.text, "Gave the file chooser “site”.")
        XCTAssertEqual(hostCommands.count, sent + 1)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "site/assets/notes.txt"), withDestinationURL: outside)
        page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 7, mode: .openFolder, title: "Upload a folder",
                                                                   defaultPath: "", extensions: [])))
        let leaking = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("site")])])
        XCTAssertTrue(leaking.isError && leaking.text.contains("holds a link that leads outside"), leaking.text)
        XCTAssertEqual(hostCommands.count, sent + 1, "The chooser is not answered")
        _ = await run(AgentToolCatalog.fileUpload, ["paths": .array([])])

        // The chooser a click opens reaches Yardlet a moment after the click's result; the upload right after waits for it.
        tools.fileChooserWait = .seconds(10)
        let page = page!
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 6, mode: .openMultiple, title: "", defaultPath: "", extensions: [])))
        }
        let cancelled = await run(AgentToolCatalog.fileUpload, [:])
        XCTAssertEqual(cancelled.text, "Cancelled the file chooser.")
        XCTAssertEqual(hostCommands.last, .fileDialogResult(tab: 4, dialog: 6, paths: nil))
        XCTAssertTrue(BrowserAgentWorkspaceFile.contains(URL(filePath: "/work/app"), URL(filePath: "/work/app/x")))
        XCTAssertFalse(BrowserAgentWorkspaceFile.contains(URL(filePath: "/work/app"), URL(filePath: "/work/application/x")))
    }

    // MARK: - Snapshot and references

    func testSnapshotRendersTheTreeAndGivesActionableElementsReferences() async {
        let result = await loadSnapshot()
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, """
            Page URL: https://example.com/
            Page title: Example Domain
            Snapshot 1 of tab 4

            - heading "Welcome" [level=1] [ref=@e1]
            - textbox "Name" [required] [ref=@e2]: "Ada"
            - button "Send" [ref=@e3]
            - paragraph: "Hello world"
            - link "Docs" [url=/docs] [ref=@e4]
            """, "references only on what an agent acts on; a link on the page's own site reads as its path")
        XCTAssertEqual(page.refs, ["@e1": .init(node: 10), "@e2": .init(node: 12), "@e3": .init(node: 13), "@e4": .init(node: 15)])
    }

    /// Each frame's tree goes under the iframe that holds it; a frame from another site says its origin, and its
    /// elements' references carry its session. Separators and a container's name taken from its own text go.
    func testSnapshotPlacesEachFramesTreeUnderItsIframe() {
        func node(_ id: String, _ role: String, _ name: String = "", parent: String? = nil, children: [String] = [],
                  backend: Int64? = nil, url: String? = nil, fromContents: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "role": .object(["value": .string(role)]),
                "name": .object(["value": .string(name), "sources": .array(fromContents
                    ? [.object(["type": .string("contents"), "value": .object(["value": .string(name)])])] : [])]),
                "childIds": .array(children.map { .string($0) }),
                "properties": .array(url.map { [.object(["name": .string("url"), "value": .object(["value": .string($0)])])] } ?? [])
            ]
            if let parent { fields["parentId"] = .string(parent) }
            if let backend { fields["backendDOMNodeId"] = .integer(backend) }
            return .object(fields)
        }
        let page = BrowserAgentSnapshot.Frame(nodes: [
            node("1", "RootWebArea", "Shop", children: ["2", "3", "4"], backend: 1, url: "https://shop.test/cart"),
            node("2", "cell", "Total | 10", parent: "1", children: ["2a", "2b", "2c"], backend: 2, fromContents: true),
            node("2a", "StaticText", "Total", parent: "2"), node("2b", "StaticText", "|", parent: "2"),
            node("2c", "StaticText", "10", parent: "2"),
            node("3", "Iframe", "Card", parent: "1", backend: 3),
            node("4", "Iframe", "Hidden ad", parent: "1", backend: 4)
        ], children: [3: 1])
        let card = BrowserAgentSnapshot.Frame(nodes: [
            node("1", "RootWebArea", "Card", children: ["2"], backend: 1, url: "https://pay.test/frame?secret=x"),
            node("2", "textbox", "Card number", parent: "1", backend: 3)
        ], session: "S1")
        let rendered = BrowserAgentSnapshot.render(frames: [page, card])
        XCTAssertEqual(rendered.text, """
            - cell: "Total 10"
            - Iframe "Card" [origin=https://pay.test] [ref=@e1]
              - textbox "Card number" [ref=@e2]
            - Iframe "Hidden ad" [ref=@e3]
            """)
        XCTAssertEqual(rendered.refs["@e2"], BrowserAgentSnapshot.Ref(node: 3, session: "S1"),
                       "the same backend id in another process is a different element")
        XCTAssertEqual(rendered.refs["@e1"], BrowserAgentSnapshot.Ref(node: 3, session: nil))

        // A page nested deeper than any reader needs, or a tree that loops, is cut instead of running out of stack.
        let deep = [node("0", "RootWebArea", "Deep", children: ["n0"])] + (0..<5_000).map {
            node("n\($0)", "generic", parent: $0 == 0 ? "0" : "n\($0 - 1)", children: ["n\($0 + 1)"])
        }
        XCTAssertTrue(BrowserAgentSnapshot.render(nodes: deep).isTruncated)
        let loop = [node("0", "RootWebArea", children: ["a"]), node("a", "group", "A", parent: "0", children: ["b"]),
                    node("b", "group", "B", parent: "a", children: ["a"])]
        XCTAssertTrue(BrowserAgentSnapshot.render(nodes: loop).isTruncated)
    }

    func testReferencesNeedASnapshotAndExpireWithTheNextOneOrANavigation() async {
        let beforeSnapshot = await run(AgentToolCatalog.click, ["ref": .string("@e1")])
        XCTAssertTrue(beforeSnapshot.isError)
        XCTAssertTrue(beforeSnapshot.text.contains("Call browser_snapshot first"), beforeSnapshot.text)

        _ = await loadSnapshot()
        let unknown = await run(AgentToolCatalog.click, ["ref": .string("@e99")])
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.failure?.kind, .notFound)
        XCTAssertEqual(unknown.failure?.retry, .withChanges)
        XCTAssertTrue(unknown.text.contains("No snapshot of tab 4 gave @e99: they gave @e1 to @e4 so far"), unknown.text)

        // An element keeps its reference in the next snapshot; one that left the page takes its own with it, and a new
        // one gets a number no snapshot gave before.
        let tree = cdp.responders["Accessibility.getFullAXTree"]!
        cdp.responders["Accessibility.getFullAXTree"] = { params in
            // The link goes, and a button takes its place in the tree.
            let nodes = (try tree(params)["nodes"]?.arrayValue ?? []).map { node -> JSONValue in
                guard node["nodeId"]?.stringValue == "9" else { return node }
                return .object(["nodeId": .string("9"), "ignored": .bool(false), "parentId": .string("1"),
                                "role": .object(["type": .string("role"), "value": .string("button")]),
                                "name": .object(["type": .string("computedString"), "value": .string("More")]),
                                "childIds": .array([]), "properties": .array([]), "backendDOMNodeId": .integer(16)])
            }
            return .object(["nodes": .array(nodes)])
        }
        let second = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(second.text.contains("Snapshot 2 of tab 4"), second.text)
        XCTAssertTrue(second.text.contains("button \"Send\" [ref=@e3]"), second.text)
        XCTAssertTrue(second.text.contains("button \"More\" [ref=@e5]"), second.text)
        let left = await run(AgentToolCatalog.click, ["ref": .string("@e4")])
        XCTAssertTrue(left.text.contains("@e4 is not in snapshot 2 of tab 4, the latest: an earlier snapshot gave it"), left.text)
        cdp.responders["Accessibility.getFullAXTree"] = tree

        cdp.responders["DOM.scrollIntoViewIfNeeded"] = { _ in throw ScriptedCDP.missingNode("DOM.scrollIntoViewIfNeeded") }
        let stale = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.text.contains("@e3 is stale"), stale.text)
        XCTAssertFalse(cdp.methods.contains("Input.dispatchMouseEvent"), "A stale reference clicks nothing")

        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        _ = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com/#top")])
        let afterNavigation = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(afterNavigation.text.contains("@e3 is stale: the page navigated after snapshot 2 of tab 4"), afterNavigation.text)
    }

    /// A link the agent clicked navigates without the navigate tool. The old document can stay
    /// alive in the back/forward cache and still answer for its nodes, so the navigation itself
    /// has to end the references.
    func testAMainFrameNavigationAfterTheSnapshotMakesItsReferencesStale() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.getContentQuads"] = { _ in
            .object(["quads": .array([.array([0, 0, 10, 0, 10, 10, 0, 10].map { .number($0) })])])
        }
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("child"), "parentId": .string("main")])])))
        let afterFrame = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertFalse(afterFrame.isError, "An iframe navigating leaves the page's references alone")

        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("main"), "url": .string("https://example.com/second")])])))
        cdp.sent = []
        let afterNavigation = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(afterNavigation.isError)
        XCTAssertTrue(afterNavigation.text.contains("@e3 is stale: the page went to https://example.com/second after snapshot 1"),
                      afterNavigation.text)
        XCTAssertFalse(cdp.methods.contains("Input.dispatchMouseEvent"), "Nothing is clicked at the old position")

        // The new document's elements get numbers no snapshot of the tab gave before. A click that makes the page
        // navigate says that the references ended, as a batch's later actions need them.
        let renewed = await loadSnapshot()
        XCTAssertTrue(renewed.text.contains("button \"Send\" [ref=@e7]"), renewed.text)
        cdp.eventsAfter["Input.dispatchMouseEvent"] = [("Page.frameNavigated",
            .object(["frame": .object(["id": .string("main"), "url": .string("https://example.com/third")])]))]
        let submitted = await run(AgentToolCatalog.click, ["ref": .string("@e7")])
        XCTAssertFalse(submitted.isError, submitted.text)
        XCTAssertTrue(submitted.text.contains("The page went to https://example.com/third during this browser_click, so the "
            + "references of snapshot 2 of tab 4 no longer apply"), submitted.text)
    }

    // MARK: - Input

    func testClickByReferenceUsesTheElementCentreAndTrustedMouseEvents() async throws {
        // A read does not act on the page; a click does (what the page downloads after it is the agent's), and one that
        // fails before it reaches the page is taken back.
        var acted = 0, failed = 0
        page.agentActs = { acted += 1 }
        page.agentActFailed = { failed += 1 }
        _ = await loadSnapshot()
        XCTAssertEqual(acted, 0)
        let stale = await run(AgentToolCatalog.click, ["ref": .string("@e99")])
        XCTAssertTrue(stale.isError)
        XCTAssertEqual([acted, failed], [1, 1])
        acted = 0
        cdp.responders["DOM.getContentQuads"] = { _ in
            .object(["quads": .array([.array([10, 20, 110, 20, 110, 60, 10, 60].map { .number($0) })])])
        }
        let result = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertEqual([acted, failed], [1, 1])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Clicked @e3 at (60, 40).")
        XCTAssertEqual(cdp.params(of: "DOM.scrollIntoViewIfNeeded").first?["backendNodeId"], .integer(13))
        let mouse = cdp.params(of: "Input.dispatchMouseEvent")
        XCTAssertEqual(mouse.map { $0["type"]?.stringValue }, ["mouseMoved", "mousePressed", "mouseReleased"])
        XCTAssertEqual(mouse[1]["x"], .number(60))
        XCTAssertEqual(mouse[1]["y"], .number(40))
        XCTAssertEqual(mouse[1]["button"], .string("left"))
        XCTAssertEqual(mouse[1]["clickCount"], .integer(1))
        XCTAssertEqual(mouse[1]["buttons"], .integer(1))
    }

    func testClickAtAPointCanDoubleClickWithAnotherButtonAndModifiers() async {
        let result = await run(AgentToolCatalog.click, [
            "x": .number(5), "y": .number(6), "doubleClick": .bool(true), "button": .string("right"),
            "modifiers": .array([.string("Shift"), .string("Meta")])
        ])
        XCTAssertFalse(result.isError, result.text)
        let mouse = cdp.params(of: "Input.dispatchMouseEvent")
        XCTAssertEqual(mouse.map { $0["type"]?.stringValue }, ["mouseMoved", "mousePressed", "mouseReleased", "mousePressed", "mouseReleased"])
        XCTAssertEqual(mouse[3]["clickCount"], .integer(2))
        XCTAssertEqual(mouse[3]["button"], .string("right"))
        XCTAssertEqual(mouse[3]["modifiers"], .integer(12))
        let missing = await run(AgentToolCatalog.click, [:])
        XCTAssertTrue(missing.isError)
    }

    func testTypeFocusesSelectsTheOldTextInsertsTrustedTextAndSubmits() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-12")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("field")) }
        let result = await run(AgentToolCatalog.type, ["ref": .string("@e2"), "text": .string("Grace"), "submit": .bool(true)])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Typed 5 characters into @e2 and pressed Enter.")
        XCTAssertEqual(cdp.params(of: "DOM.focus").first?["backendNodeId"], .integer(12))
        XCTAssertEqual(cdp.params(of: "Runtime.callFunctionOn").first?["objectId"], .string("obj-12"))
        XCTAssertEqual(cdp.params(of: "Input.insertText").first?["text"], .string("Grace"))
        let keys = cdp.params(of: "Input.dispatchKeyEvent")
        XCTAssertEqual(keys.map { $0["type"]?.stringValue }, ["keyDown", "keyUp"])
        XCTAssertEqual(keys[0]["key"], .string("Enter"))
        XCTAssertEqual(keys[0]["text"], .string("\r"))
        XCTAssertEqual(keys[0]["windowsVirtualKeyCode"], .integer(13))
    }

    /// A sign-in the agent types goes into the task's profile of its own: typed before the task takes one, it would
    /// change the person's sign-in in every task (docs/BROWSER_SESSION_ISOLATION.md 3).
    func testTypeIntoAPasswordOrCodeFieldGivesTheTaskAProfileOfItsOwnBeforeAnythingGoesIn() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-12")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("signIn")) }
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object(["id": .string("main"), "securityOrigin": .string("https://www.example.com")])])])
        }
        var taken: [String] = []
        tools.takesOwnProfile = { _, host, _ in
            taken.append(host)
            return taken.count == 1
        }
        let first = await run(AgentToolCatalog.type, ["ref": .string("@e2"), "text": .string("secret")])
        XCTAssertTrue(first.isError)
        XCTAssertTrue(first.text.contains("profile of its own") && first.text.contains("browser_snapshot"), first.text)
        XCTAssertTrue(cdp.params(of: "Input.insertText").isEmpty, "nothing goes into the page that opened again")
        let second = await run(AgentToolCatalog.type, ["ref": .string("@e2"), "text": .string("secret")])
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(taken, ["www.example.com", "www.example.com"])
        XCTAssertEqual(cdp.params(of: "Input.insertText").first?["text"], .string("secret"))
    }

    /// A sign-in can also go in key by key, or through a script with no field typed into: a task in the default profile
    /// takes one of its own before a character goes into a password field, and before its first script runs.
    func testKeysIntoAPasswordFieldAndTheFirstScriptGiveTheTaskAProfileOfItsOwnFirst() async {
        let focused = Box("password")
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object(["id": .string("main"), "securityOrigin": .string("https://www.example.com")])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { _ in .object(["executionContextId": .integer(7)]) }
        cdp.responders["Runtime.evaluate"] = { params in
            if params["contextId"] == .integer(7) { return ScriptedCDP.value(.string(focused.value)) }
            if params["objectGroup"] != nil { return .object(["result": .object(["type": .string("object"), "objectId": .string("none")])]) }
            return ScriptedCDP.value(.integer(1))
        }
        var taken: [String] = []
        var owns = false
        tools.takesOwnProfile = { _, _, how in
            taken.append(how)
            defer { owns = true }
            return !owns
        }
        func keyDowns() -> [String?] { cdp.params(of: "Input.dispatchKeyEvent").filter { $0["type"] != .string("keyUp") }.map { $0["key"]?.stringValue } }

        // Enter puts no text in, and a field that is no password field is no sign-in.
        let enter = await run(AgentToolCatalog.pressKey, ["key": .string("Enter")])
        focused.value = "other"
        let elsewhere = await run(AgentToolCatalog.pressKey, ["key": .string("a")])
        XCTAssertFalse(enter.isError || elsewhere.isError, enter.text + elsewhere.text)
        XCTAssertEqual(taken, [])

        focused.value = "password"
        let first = await run(AgentToolCatalog.pressKey, ["key": .string("a")])
        XCTAssertTrue(first.isError)
        XCTAssertTrue(first.text.contains("profile of its own") && first.text.contains("press the key again"), first.text)
        XCTAssertEqual(keyDowns(), ["Enter", "a"], "the key goes to no page that opened again")
        let second = await run(AgentToolCatalog.pressKey, ["key": .string("a")])
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(keyDowns(), ["Enter", "a", "a"])

        owns = false
        taken = []
        func scripts() -> Int { cdp.params(of: "Runtime.evaluate").filter { $0["awaitPromise"] == .bool(true) }.count }
        let before = scripts()
        let script = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(script.isError)
        XCTAssertTrue(script.text.contains("did not run") && script.text.contains("browser_evaluate again"), script.text)
        XCTAssertEqual(scripts(), before, "the function did not run")
        let again = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(scripts(), before + 1)
        XCTAssertEqual(taken, ["page script", "page script"])
    }

    func testTypeRefusesAnElementThatIsNotATextField() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-13")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("other")) }
        let result = await run(AgentToolCatalog.type, ["ref": .string("@e3"), "text": .string("x")])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not an editable text field"), result.text)
        XCTAssertTrue(cdp.params(of: "Input.insertText").isEmpty)
    }

    func testPressKeyHoldsModifiersAndCarriesMacEditingCommands() async {
        let result = await run(AgentToolCatalog.pressKey, ["key": .string("Meta+a")])
        XCTAssertFalse(result.isError, result.text)
        let keys = cdp.params(of: "Input.dispatchKeyEvent")
        XCTAssertEqual(keys.map { $0["type"]?.stringValue }, ["rawKeyDown", "rawKeyDown", "keyUp", "keyUp"])
        XCTAssertEqual(keys.map { $0["key"]?.stringValue }, ["Meta", "a", "a", "Meta"])
        XCTAssertEqual(keys.map { $0["modifiers"] }, [.integer(4), .integer(4), .integer(4), .integer(0)])
        XCTAssertEqual(keys[1]["commands"], .array([.string("selectAll")]))
        XCTAssertNil(keys[1]["text"], "A shortcut types nothing")

        cdp.sent = []
        _ = await run(AgentToolCatalog.pressKey, ["key": .string("Backspace")])
        XCTAssertEqual(cdp.params(of: "Input.dispatchKeyEvent").first?["commands"], .array([.string("deleteBackward")]))

        let unknown = await run(AgentToolCatalog.pressKey, ["key": .string("Hyper+x")])
        XCTAssertTrue(unknown.isError)
    }

    func testKeyNamesParseLikeAPlaywrightKeyboard() throws {
        let shiftTab = try XCTUnwrap(BrowserAgentKeyPress.parse("Shift+Tab"))
        XCTAssertEqual(shiftTab.key.keyCode, 9)
        XCTAssertEqual(shiftTab.modifierBits, 8)
        let shiftedLetter = try XCTUnwrap(BrowserAgentKeyPress.parse("Shift+a"))
        XCTAssertEqual(shiftedLetter.key.key, "A")
        XCTAssertEqual(shiftedLetter.key.text, "A")
        XCTAssertEqual(shiftedLetter.key.code, "KeyA")
        XCTAssertEqual(BrowserAgentKeyPress.parse("Esc")?.key.keyCode, 27)
        XCTAssertEqual(BrowserAgentKeyPress.parse("Meta++")?.key.code, "Equal")
        XCTAssertEqual(BrowserAgentKeyPress.parse("?")?.key.code, "Slash")
        XCTAssertEqual(BrowserAgentKeyPress.parse("한")?.key.text, "한")
        XCTAssertEqual(BrowserAgentKeyPress.parse("Shift+Meta+z")?.macEditingCommands, ["redo"])
        XCTAssertEqual(BrowserAgentKeyPress.parse("Alt+ArrowLeft")?.macEditingCommands, ["moveWordLeft"])
        XCTAssertNil(BrowserAgentKeyPress.parse(""))
        XCTAssertNil(BrowserAgentKeyPress.parse("Enterprise"))
    }

    func testScrollSendsAWheelEventAtThePageCentreAndReportsThePosition() async {
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object(["cssVisualViewport": .object(["clientWidth": .number(1000), "clientHeight": .number(600),
                                                     "pageX": .number(0), "pageY": .number(0)])])
        }
        let result = await run(AgentToolCatalog.scroll, ["deltaY": .number(400)])
        XCTAssertFalse(result.isError, result.text)
        let wheel = cdp.params(of: "Input.dispatchMouseEvent").first
        XCTAssertEqual(wheel?["type"], .string("mouseWheel"))
        XCTAssertEqual(wheel?["x"], .number(500))
        XCTAssertEqual(wheel?["y"], .number(300))
        XCTAssertEqual(wheel?["deltaY"], .number(400))
        XCTAssertEqual(result.text, "Scrolled. The page is at x=0, y=400 of 1280×5000.")
    }

    func testSelectOptionPassesTheValuesAndNamesTheOptionsWhenOneIsMissing() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { params in
            let wanted = params["arguments"]?.arrayValue?.first?["value"]?.arrayValue?.first?.stringValue
            return wanted == "Blue"
                ? ScriptedCDP.value(.object(["selected": .array([.string("Blue")])]))
                : ScriptedCDP.value(.object(["error": .string("has no option \"Pink\""),
                                             "options": .array([.string("Red"), .string("Blue")])]))
        }
        let chosen = await run(AgentToolCatalog.selectOption, ["ref": .string("@e2"), "values": .array([.string("Blue")])])
        XCTAssertEqual(chosen.text, "Selected \"Blue\" in @e2.")
        let missing = await run(AgentToolCatalog.selectOption, ["ref": .string("@e2"), "values": .array([.string("Pink")])])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("Options: Red, Blue"), missing.text)
    }

    // MARK: - Reading the page

    func testWaitForLooksAgainUntilTheTextAppearsAndFailsAfterItsTimeout() async {
        cdp.bodyTexts = ["Loading", "Loading", "Saved"]
        let appeared = await run(AgentToolCatalog.waitFor, ["text": .string("Saved")])
        XCTAssertEqual(appeared.text, "\"Saved\" appeared.")

        // A part of the visible text, ignoring case and runs of spaces, as Playwright's text matching reads it.
        cdp.bodyTexts = ["ORDER\n  saved\u{00A0}today"]
        let loosely = await run(AgentToolCatalog.waitFor, ["text": .string("Order saved today")])
        XCTAssertEqual(loosely.text, "\"Order saved today\" appeared.")

        // A wait that runs out says what the page shows, so the same wait is not tried again blind.
        cdp.bodyTexts = ["Loading"]
        let timedOut = await run(AgentToolCatalog.waitFor, ["text": .string("Saved"), "timeout": .number(0.05)])
        XCTAssertTrue(timedOut.isError)
        XCTAssertTrue(timedOut.text.contains("for “Saved” to appear in the visible text of the page and of its frames from the "
            + "same origin, ignoring case and runs of spaces; it did not."), timedOut.text)
        XCTAssertTrue(timedOut.text.contains("The page is at https://example.com/ (“Example Domain”) and has loaded."), timedOut.text)
        XCTAssertTrue(timedOut.text.contains("Its text now: “Loading”"), timedOut.text)
        XCTAssertEqual(timedOut.failure, AgentToolFailure(.timedOut, retry: .withChanges, details: ["seconds": .number(0.05), "loaded": .bool(true)]),
                       "on a loaded page the same wait is no likelier to succeed")
        cdp.bodyTexts = ["Uploading 3 files, spinner shown"]
        let stillThere = await run(AgentToolCatalog.waitFor, ["textGone": .string("SPINNER"), "timeout": .number(0.05)])
        XCTAssertTrue(stillThere.text.contains("It is still in the page's text: “Uploading 3 files, spinner shown”"), stillThere.text)
        cdp.bodyTexts = [""]

        let gone = await run(AgentToolCatalog.waitFor, ["textGone": .string("Spinner")])
        XCTAssertEqual(gone.text, "\"Spinner\" is gone.")
        let nothing = await run(AgentToolCatalog.waitFor, [:])
        XCTAssertTrue(nothing.isError)
    }

    func testScreenshotIsAnImageAtOneImagePixelPerCSSPixel() async throws {
        cdp.pixelRatio = 2
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object([
                "cssVisualViewport": .object(["clientWidth": .number(1280), "clientHeight": .number(800),
                                              "pageX": .number(0), "pageY": .number(120)]),
                "cssContentSize": .object(["width": .number(1280), "height": .number(3000)])
            ])
        }
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("iVBORw0KGgo=")]) }
        let result = await run(AgentToolCatalog.screenshot)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.content.first, .image(data: "iVBORw0KGgo=", mimeType: "image/png"))
        let clip = try XCTUnwrap(cdp.params(of: "Page.captureScreenshot").first?["clip"])
        XCTAssertEqual(clip["y"], .number(120))
        XCTAssertEqual(clip["width"], .number(1280))
        XCTAssertEqual(clip["scale"], .number(0.5))

        _ = await run(AgentToolCatalog.screenshot, ["fullPage": .bool(true), "format": .string("jpeg")])
        let full = try XCTUnwrap(cdp.params(of: "Page.captureScreenshot").last)
        XCTAssertEqual(full["captureBeyondViewport"], .bool(true))

        // A capture that waits asks the tab for frames until it is answered.
        var asks = 0
        page.askForFrame = { asks += 1 }
        tools.frameAskInterval = .milliseconds(10)
        cdp.suspendOn = ["Page.captureScreenshot"]
        let waiting = Task { await run(AgentToolCatalog.screenshot) }
        try await waitUntil { asks >= 2 }
        cdp.suspendOn = []
        cdp.resumeSuspended()
        let waited = await waiting.value
        XCTAssertFalse(waited.isError, waited.text)

        // A tab that draws no frame for the capture, while its page answers other calls, says so.
        cdp.responders["Page.captureScreenshot"] = { _ in throw BrowserDevToolsError.timedOut("Page.captureScreenshot") }
        page.rendererAnswered = { _ in true }
        let undrawn = await run(AgentToolCatalog.screenshot)
        XCTAssertTrue(undrawn.text.hasPrefix("The tab drew no picture for the screenshot within 30 seconds."), undrawn.text)
        XCTAssertTrue(undrawn.text.contains("no frame of the page came meanwhile"), undrawn.text)
        XCTAssertEqual(undrawn.failure?.retry, .withChanges)
        XCTAssertEqual(undrawn.failure?.details["framesWhileWaiting"], .bool(false))
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("iVBORw0KGgo=")]) }
        XCTAssertEqual(full["format"], .string("jpeg"))
        XCTAssertEqual(full["clip"]?["height"], .number(3000))

        // CEF's windowless view does not grow for Chromium's capture, so the tab is drawn at the page's size
        // for it: the layout viewport held first, the view back before the hold ends, and no more than a GPU
        // texture's 16,384 device pixels.
        let viewport = BrowserViewport(width: 1280, height: 800, scale: 2)
        page.viewport = { [unowned self] in
            self.hostCommands.reversed().lazy.compactMap { if case .resize(_, let size) = $0 { size } else { nil } }.first ?? viewport
        }
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object([
                "cssVisualViewport": .object(["clientWidth": .number(1280), "clientHeight": .number(800)]),
                "cssContentSize": .object(["width": .number(1280), "height": .number(20_000)])
            ])
        }
        var commandsAt: [String: Int] = [:]
        for method in ["Emulation.setDeviceMetricsOverride", "Page.captureScreenshot", "Emulation.clearDeviceMetricsOverride"] {
            cdp.responders[method] = { [unowned self] _ in
                commandsAt[method] = self.hostCommands.count
                return .object(["data": .string("iVBORw0KGgo=")])
            }
        }
        let tall = await run(AgentToolCatalog.screenshot, ["fullPage": .bool(true)])
        XCTAssertEqual(commandsAt, ["Emulation.setDeviceMetricsOverride": 0, "Page.captureScreenshot": 1,
                                    "Emulation.clearDeviceMetricsOverride": 2])
        XCTAssertEqual(cdp.params(of: "Emulation.setDeviceMetricsOverride").last?["height"], .integer(800))
        XCTAssertEqual(hostCommands, [.resize(tab: 4, viewport: BrowserViewport(width: 1280, height: 8190, scale: 2)),
                                      .resize(tab: 4, viewport: viewport)])
        XCTAssertEqual(cdp.params(of: "Page.captureScreenshot").last?["clip"]?["height"], .number(8190))
        XCTAssertTrue(tall.text.contains("The page is 20000 CSS pixels tall; this is its top."), tall.text)
    }

    func testConsoleMessagesListConsoleCallsLogEntriesAndUncaughtErrors() async {
        cdp.eventLog = [
            ("Runtime.consoleAPICalled", .object(["type": .string("log"), "args": .array([
                .object(["type": .string("string"), "value": .string("ready")]),
                .object(["type": .string("number"), "value": .integer(3)])
            ])])),
            ("Runtime.exceptionThrown", .object(["exceptionDetails": .object([
                "text": .string("Uncaught"), "exception": .object(["description": .string("TypeError: x is undefined")])
            ])])),
            ("Log.entryAdded", .object(["entry": .object([
                "level": .string("error"), "text": .string("Failed to load resource"), "url": .string("https://example.com/a.js")
            ])])),
            ("Page.loadEventFired", .object([:]))
        ]
        let all = await run(AgentToolCatalog.consoleMessages)
        XCTAssertEqual(all.text, """
            [log] ready 3
            [uncaught] TypeError: x is undefined
            [error] Failed to load resource (https://example.com/a.js)
            """)
        let errors = await run(AgentToolCatalog.consoleMessages, ["onlyErrors": .bool(true)])
        XCTAssertFalse(errors.text.contains("ready"))
    }

    func testEvaluateReturnsTheResultAsJSONAndReportsWhatTheFunctionThrew() async {
        cdp.responders["Runtime.evaluate"] = { params in
            let expression = params["expression"]?.stringValue ?? ""
            if expression.contains("boom") {
                return .object(["result": .object(["type": .string("object")]),
                                "exceptionDetails": .object(["text": .string("Uncaught"),
                                                             "exception": .object(["description": .string("Error: boom")])])])
            }
            return ScriptedCDP.value(.object(["count": .integer(2)]))
        }
        let value = await run(AgentToolCatalog.evaluate, ["function": .string("() => ({ count: 2 })")])
        XCTAssertFalse(value.isError, value.text)
        XCTAssertTrue(value.text.contains("\"count\" : 2"), value.text)
        let sent = cdp.params(of: "Runtime.evaluate").first
        XCTAssertEqual(sent?["awaitPromise"], .bool(true))
        XCTAssertEqual(sent?["returnByValue"], .bool(true))
        XCTAssertTrue(sent?["expression"]?.stringValue?.contains("() => ({ count: 2 })") == true)

        let thrown = await run(AgentToolCatalog.evaluate, ["function": .string("() => { throw new Error('boom') }")])
        XCTAssertTrue(thrown.isError)
        XCTAssertTrue(thrown.text.contains("Error: boom"), thrown.text)
    }

    /// The vault's values reach the page and nothing the model reads: not the fill's result, not a later
    /// snapshot that echoes one or shows a filled field, not a screenshot or the console of the filled document, and
    /// browser_evaluate waits while the filled document is shown, whoever filled it (docs/BROWSER_VAULT_DESIGN.md §5.3).
    func testAVaultFillKeepsItsValuesOutOfResultsAndPausesEvaluateWhileTheyAreOnThePage() async {
        let item = VaultItem(name: "Example", sites: ["example.com"], username: "ada", policy: .always)
        var confirms = true
        var asked: [String] = []
        // A sign-in that asks for an organization's ID in a masked field beside the password.
        let organization = VaultFormField(id: "orgId", name: "orgId", label: "Organization ID", value: "org-id-4821")
        tools.vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct-horse-battery", fields: [organization])]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            confirm: { asked.append($0); return confirms }, defaults: .vaultTests()))
        _ = await loadSnapshot()
        var loader = "doc-1"
        var secretNodes: [Int64] = [3]
        var failFill = false
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object([
                "id": .string("main"), "loaderId": .string(loader), "url": .string("https://www.example.com/login"),
                "securityOrigin": .string("https://www.example.com")
            ])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { _ in .object(["executionContextId": .integer(7)]) }
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("field")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { params in
            let function = params["functionDeclaration"]?.stringValue ?? ""
            if function.contains("ownerDocument === document") { return ScriptedCDP.value(.bool(true)) }
            if failFill, function == BrowserAgentTools.fillFunction { throw BrowserDevToolsError.timedOut("Runtime.callFunctionOn") }
            return ScriptedCDP.value(.object(["kinds": .array([.string("password"), .string("username")])]))
        }
        cdp.responders["Runtime.evaluate"] = { params in
            if params["objectGroup"] != nil { return .object(["result": .object(["type": .string("object"), "objectId": .string("found")])]) }
            if params["contextId"] != nil { return .object(["result": .object(["type": .string("object"), "objectId": .string("person-field")])]) }
            return ScriptedCDP.value(.array([.string("https://www.example.com/login"), .string("Sign in")]))
        }
        cdp.responders["Runtime.getProperties"] = { _ in
            .object(["result": .array(secretNodes.indices.map { .object(["name": .string(String($0)),
                                                                          "value": .object(["objectId": .string("node-\($0)")])]) }
                + [.object(["name": .string("length"), "value": .object(["value": .integer(Int64(secretNodes.count))])])])])
        }
        cdp.responders["DOM.describeNode"] = { params in
            let index = Int(params["objectId"]?.stringValue?.dropFirst("node-".count) ?? "") ?? 0
            return .object(["node": .object(["backendNodeId": .integer(secretNodes[index])])])
        }
        func console(_ text: String) {
            cdp.eventLog.append(("Runtime.consoleAPICalled", .object(["type": .string("log"),
                                                                     "args": .array([.object(["type": .string("string"), "value": .string(text)])])])))
        }
        func navigate(to document: String) {
            loader = document
            cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object([
                "id": .string("main"), "loaderId": .string(document), "url": .string("https://www.example.com/")])])))
        }
        console("before the fill")

        let filled = await run(VaultToolCatalog.fillCredential, ["ref": .string("@e2")])
        XCTAssertFalse(filled.isError, filled.text)
        XCTAssertFalse(filled.text.contains("correct-horse-battery"), filled.text)
        XCTAssertTrue(filled.text.contains("the username and password of “Example”"), filled.text)
        let fill = cdp.params(of: "Runtime.callFunctionOn").last { $0["functionDeclaration"]?.stringValue == BrowserAgentTools.fillFunction }
        XCTAssertEqual(fill?["objectId"], .string("field"))
        XCTAssertTrue(fill?["arguments"]?.arrayValue?.contains(.object(["value": .string("correct-horse-battery")])) == true)
        XCTAssertTrue(fill?["arguments"]?.arrayValue?.contains(.object(["value": .string("https://www.example.com")])) == true,
                      "The fill checks the document's origin as it fills")
        XCTAssertEqual(fill?["arguments"]?.arrayValue?.last?["value"]?.arrayValue?.first?["value"], .string("org-id-4821"),
                       "The sign-in's other secret fills with the password")
        let organizationEcho = await run(AgentToolCatalog.waitFor, ["text": .string("org-id-4821"), "timeout": .number(0.01)])
        XCTAssertFalse(organizationEcho.text.contains("org-id-4821"), organizationEcho.text)
        // A failure's structured content, which a harness shows in place of the text, is scrubbed too.
        let waited = await run(AgentToolCatalog.waitFor, ["text": .string("correct-horse-battery"), "timeout": .number(0.01)])
        XCTAssertEqual(waited.failure?.kind, .timedOut)
        XCTAssertFalse(String(describing: waited.structuredContent).contains("correct-horse-battery"), waited.text)
        XCTAssertFalse(waited.text.contains("correct-horse-battery"), waited.text)

        func axNode(_ id: String, _ role: String, _ name: String, parent: String?, children: [String] = [],
                    value: String? = nil) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "ignored": .bool(false), "backendDOMNodeId": .integer(Int64(id) ?? 0),
                "childIds": .array(children.map { .string($0) }), "role": .object(["value": .string(role)]),
                "name": .object(["value": .string(name)])
            ]
            if let parent { fields["parentId"] = .string(parent) }
            if let value { fields["value"] = .object(["value": .string(value)]) }
            return .object(fields)
        }
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                axNode("1", "RootWebArea", "Sign in", parent: nil, children: ["2", "3", "10"]),
                axNode("2", "paragraph", "", parent: "1", children: ["4"]),
                axNode("4", "StaticText", "Signed in with correct-horse-battery as Y29ycmVjdC1ob3JzZS1iYXR0ZXJ5, 636f72726563742d686f7273652d62617474657279", parent: "2"),
                axNode("3", "textbox", "Password", parent: "1", value: "•••••••••••••••••••••"),
                axNode("10", "group", "Code", parent: "1", children: (11...16).map(String.init))
            ] + (11...16).map { axNode(String($0), "textbox", "", parent: "10", value: String($0 - 10)) })])
        }
        let echoed = await run(AgentToolCatalog.snapshot)
        XCTAssertFalse(echoed.text.contains("correct-horse-battery"), echoed.text)
        XCTAssertEqual(echoed.text.components(separatedBy: "[saved value]").count, 4,
                       "The value as written, in base64 and in hex: \(echoed.text)")
        XCTAssertFalse(BrowserAgentTools.fillFunction.contains("data: v"), "The input event does not carry the value")
        XCTAssertTrue(echoed.text.contains("textbox \"Password\" [ref=\(Self.refs(in: echoed.text)[0])]: \"<redacted>\""), echoed.text)
        // A code over one-digit boxes matches no scrubbed string: the boxes the fill went into are left out by node.
        secretNodes = Array(11...16)
        let boxes = await run(AgentToolCatalog.snapshot)
        XCTAssertEqual(boxes.text.components(separatedBy: "\"<redacted>\"").count, 8, "Six boxes and the password: \(boxes.text)")
        XCTAssertFalse((1...6).contains { boxes.text.contains("\"\($0)\"") }, boxes.text)

        let paused = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(paused.isError)
        XCTAssertTrue(paused.text.contains("password or code"), paused.text)
        let picture = await run(AgentToolCatalog.screenshot)
        XCTAssertTrue(picture.isError && picture.text.contains("browser_screenshot does not run"), picture.text)
        console("c o r r e c t - h o r s e")
        let logged = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(logged.text.contains("c o r r e c t") || logged.text.contains("before the fill"), logged.text)
        XCTAssertTrue(logged.text.contains("2 messages from pages that held a password or code are left out"), logged.text)
        // A new document opens the page again; going back to the filled one closes it again.
        navigate(to: "doc-2")
        console("on the next page")
        let resumed = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(resumed.isError, resumed.text)
        let nextPage = await run(AgentToolCatalog.consoleMessages)
        XCTAssertTrue(nextPage.text.contains("on the next page"), nextPage.text)
        navigate(to: "doc-1")
        let back = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(back.isError, back.text)

        // The person's fill from the panel (the key button) closes the document for the agent alike.
        navigate(to: "doc-3")
        let open = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(open.isError, open.text)
        let byPerson = await VaultPageScripts.fillForPerson(
            cdp, frame: (id: "main", loaderID: "doc-3", origin: "https://www.example.com"), fills: page.vaultFills,
            username: "ada", password: "correct-horse-battery", code: nil)
        XCTAssertTrue(byPerson)
        let afterPerson = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(afterPerson.isError, afterPerson.text)
        // A page that moved on before the person's fill takes nothing.
        navigate(to: "doc-4")
        let moved = await VaultPageScripts.fillForPerson(
            cdp, frame: (id: "main", loaderID: "doc-3", origin: "https://www.example.com"), fills: page.vaultFills,
            username: "ada", password: "correct-horse-battery", code: nil)
        XCTAssertFalse(moved)
        let afterMove = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(afterMove.isError, afterMove.text)
        // A fill whose call fails after the values were sent keeps the document closed.
        let fourth = await run(AgentToolCatalog.snapshot)
        failFill = true
        let failed = await run(VaultToolCatalog.fillCredential, ["ref": .string(Self.refs(in: fourth.text)[1])])
        XCTAssertTrue(failed.isError, failed.text)
        let afterFailure = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(afterFailure.isError, afterFailure.text)
        failFill = false

        // The agent ran its own script on the document (the "always" item filled above without asking): the fill
        // asks the person first, and fills nothing without them.
        XCTAssertEqual(asked.count, 1, "Only the fill after browser_evaluate on doc-4 asked: \(asked)")
        navigate(to: "doc-5")
        _ = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        let fifth = Self.refs(in: await run(AgentToolCatalog.snapshot).text)[1]
        confirms = false
        let scripted = await run(VaultToolCatalog.fillCredential, ["ref": .string(fifth)])
        XCTAssertTrue(scripted.isError && scripted.text.contains("ran your own scripts"), scripted.text)
        XCTAssertEqual(asked.last, L10n.format("fill “%@” on %@ for “%@”, on a page where it ran its own scripts",
                                               "Example", "www.example.com", L10n.string("A task")))
        confirms = true

        let elsewhere = await run(VaultToolCatalog.fillCredential, ["ref": .string(fifth), "item": .string("Other")])
        XCTAssertTrue(elsewhere.isError)

        // A field in a frame from another site is not the page's own, whatever its site.
        page.replaceRefs(["@e9": .init(node: 3, session: "frame-session")], eventMark: cdp.eventLog.count)
        let framed = await run(VaultToolCatalog.fillCredential, ["ref": .string("@e9")])
        XCTAssertTrue(framed.isError && framed.text.contains("inside a frame"), framed.text)
    }

    /// A filled password stays out of addresses and other sites (docs/BROWSER_VAULT_DESIGN.md, "Filled values and
    /// addresses"): a form that sends it to a site the item does not name, or over plain http, is not filled. A safe
    /// form (POST to the page's own origin) is submitted unless the agent says not to; one that would send the password
    /// by GET or to another address of the site is filled but not submitted, whatever the agent asked. The host is told to refuse an address
    /// that carries the password before the value goes in. What the host refused reaches the next result, and the value
    /// stays out of results in the spellings a form and an address inside another's query give it.
    func testAVaultFillKeepsThePasswordOutOfAddressesAndOtherSites() async {
        let password = "p@ss word+1!"
        let item = VaultItem(name: "Example", sites: ["example.com"], username: "ada", hasPassword: true, policy: .always)
        tools.vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: password)]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        _ = await loadSnapshot()
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object([
                "id": .string("main"), "loaderId": .string("doc-1"), "url": .string("https://www.example.com/login"),
                "securityOrigin": .string("https://www.example.com")
            ])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { _ in .object(["executionContextId": .integer(7)]) }
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("field")])]) }
        func targets(_ pairs: [(String, String)]) -> JSONValue {
            .object(["form": .bool(true), "targets": .array(pairs.map { .object(["action": .string($0.0), "method": .string($0.1)]) })])
        }
        var submission = targets([])
        var guardsAtFill: [BrowserHostCommand]?
        var submits = 0
        var accountsRead = 0
        cdp.responders["Runtime.callFunctionOn"] = { [unowned self] params in
            let function = params["functionDeclaration"]?.stringValue ?? ""
            if function.contains("ownerDocument === document") { return ScriptedCDP.value(.bool(true)) }
            if function == BrowserAgentTools.submissionFunction { return ScriptedCDP.value(submission) }
            if function == BrowserAgentTools.pageAccountsFunction {
                accountsRead += 1
                return ScriptedCDP.value(.object(["values": .array([.string("grace")]), "text": .string("Sign in")]))
            }
            if function == BrowserAgentTools.submitFunction {
                submits += 1
                return ScriptedCDP.value(.string("submitted"))
            }
            guardsAtFill = self.hostCommands
            return ScriptedCDP.value(.object(["kinds": .array([.string("password"), .string("username")])]))
        }
        func fill(_ submit: Bool? = nil) async -> AgentToolResult {
            await run(VaultToolCatalog.fillCredential, ["ref": .string("@e2")].merging(submit.map { ["submit": .bool($0)] } ?? [:]) { $1 })
        }

        for elsewhere in ["https://collector.test/login", "http://www.example.com/login"] {
            submission = targets([("https://www.example.com/login", "post"), (elsewhere, "post")])
            let refused = await fill(true)
            XCTAssertTrue(refused.isError && refused.text.contains("not one of the item's sites"), refused.text)
            XCTAssertNil(guardsAtFill, "nothing went into the page")
            XCTAssertTrue(hostCommands.isEmpty)
        }

        submission = targets([("https://www.example.com/session", "post"), ("javascript:void(0)", "post")])
        let safe = await fill()
        XCTAssertTrue(safe.text.contains("and submitted it."), safe.text)
        let guarded = BrowserHostCommand.guardFilledValues(tab: 4, values: VaultScrubList.spellings(of: password))
        XCTAssertEqual(guardsAtFill, [guarded], "the host holds the value's addresses before the page has it")
        let firstStep = await fill(false)
        XCTAssertFalse(firstStep.text.contains("submit"), firstStep.text)
        XCTAssertEqual(submits, 1, "a safe form goes unless the agent says not to")

        for (unsafe, reason) in [(("https://www.example.com/login", "get"), "in the page's address"),
                                 (("https://login.example.com/session", "post"), "https://login.example.com, not to this page's")] {
            submission = targets([unsafe])
            let filled = await fill(true)
            XCTAssertFalse(filled.isError, filled.text)
            XCTAssertTrue(filled.text.contains("did not submit it") && filled.text.contains(reason), filled.text)
        }
        XCTAssertEqual(submits, 1, "an unsafe form is left unsent even when the agent asks")
        XCTAssertFalse(cdp.methods.contains("Input.dispatchKeyEvent"), "no Enter in place of the submit")
        XCTAssertEqual(accountsRead, 0, "a site with one item reads nothing of the page's account")

        // With two items for the site and none named, the account the page's username field holds is filled, and the
        // agent hears which and why.
        try? tools.vault?.save(VaultItem(name: "Other", sites: ["example.com"], username: "grace"),
                               secret: VaultSecret(password: "battery staple"))
        submission = targets([("https://www.example.com/session", "post")])
        let picked = await fill(false)
        XCTAssertEqual(accountsRead, 1)
        XCTAssertTrue(picked.text.contains("Of the 2 items saved for www.example.com, Yardlet took “Other” (grace) because "
                                           + "the page's username field holds its username"), picked.text)

        page.receive(.filledValueBlocked(tab: 4))
        cdp.pageURL = "https://www.example.com/login?email=ada&password=p%40ss+word%2b1%21"
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                .object(["nodeId": .string("1"), "ignored": .bool(false), "backendDOMNodeId": .integer(1),
                         "childIds": .array([.string("2")]), "role": .object(["value": .string("RootWebArea")]),
                         "name": .object(["value": .string("Sign in")])]),
                .object(["nodeId": .string("2"), "parentId": .string("1"), "ignored": .bool(false),
                         "backendDOMNodeId": .integer(2), "childIds": .array([]),
                         "role": .object(["value": .string("StaticText")]),
                         "name": .object(["value": .string("Back to /login?next=%2Fhome%3Fp%3Dp%2540ss%2520word%252B1%2521")])])
            ])])
        }
        let after = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(after.text.contains("tried to go to an address carrying the password"), after.text)
        XCTAssertTrue(after.text.contains("password=[saved value]"), after.text)
        XCTAssertTrue(after.text.contains("%3Fp%3D[saved value]"), "encoded twice: \(after.text)")
        XCTAssertFalse(after.text.contains("%40ss") || after.text.contains("%2540ss"), after.text)
    }

    /// A code fill on a page that shows a two-factor setup the vault does not hold (docs/BROWSER_VAULT_DESIGN.md §20)
    /// asks the person to keep it before anything is saved: Save keeps it in the site's item and its first code goes
    /// in, Not Now keeps nothing and the agent hears so. The key never reaches a result, and the page is a filled one.
    func testACodeFillOnASetupPageAsksThePersonToKeepTheSetupFirst() async {
        let item = VaultItem(name: "Example", sites: ["example.com"], username: "ada", hasPassword: true)
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct horse")]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        tools.vault = vault
        _ = await loadSnapshot()
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object([
                "id": .string("main"), "loaderId": .string("doc-1"), "url": .string("https://www.example.com/2fa"),
                "securityOrigin": .string("https://www.example.com")
            ])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { _ in .object(["executionContextId": .integer(7)]) }
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("field")])]) }
        let key = Data("setup-test-key-0001".utf8)
        var link = "otpauth://totp/Example:ada?secret=\(Base32.encode(key))&issuer=Example"
        var filledCodes: [String] = []
        cdp.responders["Runtime.callFunctionOn"] = { params in
            let function = params["functionDeclaration"]?.stringValue ?? ""
            if function.contains("ownerDocument === document") { return ScriptedCDP.value(.bool(true)) }
            if function == BrowserAgentTools.setupLookFunction {
                return ScriptedCDP.value(.object(["links": .array([.string(link)]), "square": .bool(false)]))
            }
            if function == BrowserAgentTools.submissionFunction {
                return ScriptedCDP.value(.object(["form": .bool(true), "targets": .array([
                    .object(["action": .string("https://www.example.com/2fa"), "method": .string("post")])])]))
            }
            if function == BrowserAgentTools.submitFunction { return ScriptedCDP.value(.string("submitted")) }
            if function == BrowserAgentTools.fillFunction,
               let code = params["arguments"]?.arrayValue?[3]["value"]?.stringValue { filledCodes.append(code) }
            return ScriptedCDP.value(.object(["kinds": .array([.string("one_time_code")])]))
        }
        // The person's answer on the panel's setup bar.
        var ask: BrowserVaultSetupAsk?
        var answer: (OneTimeCodeSetup) -> BrowserVaultSetupAsk.Answer = { _ in .declined }
        page.askToSaveSetup = { setup, origin in
            let new = BrowserVaultSetupAsk(id: UUID(), setup: setup, origin: origin)
            ask = new
            return (new, true)
        }
        // The person answers by the time the agent's wait looks.
        page.setupAsk = {
            if let waiting = ask, waiting.answer == nil { ask?.answer = answer(waiting.setup) }
            return ask
        }
        page.endSetupAsk = { ask = nil }
        func fill() async -> AgentToolResult {
            await run(VaultToolCatalog.fillCredential, ["ref": .string("@e2"), "kind": .string("one_time_code")])
        }

        answer = { _ in .save(.suggested) }
        let saved = await fill()
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertTrue(saved.text.contains("The person saved the page's two-factor setup in “Example”")
                      && saved.text.contains("the one-time code"), saved.text)
        XCTAssertEqual(vault.secret(of: item.id)?.oneTimeCode?.key, key, "the code went into the account's item")
        XCTAssertEqual(filledCodes.count, 1)
        XCTAssertEqual(filledCodes.first?.count, 6)
        XCTAssertNil(ask, "the ask ends once the agent read it")
        XCTAssertFalse(saved.text.contains(Base32.encode(key)))
        let evaluated = await run(AgentToolCatalog.evaluate, ["function": .string("() => document.title")])
        XCTAssertTrue(evaluated.isError && evaluated.text.contains("password or code"), evaluated.text)

        // Not Now: nothing is saved or filled.
        let other = Data("setup-test-key-0002".utf8)
        link = "otpauth://totp/Example:ada?secret=\(Base32.encode(other))&issuer=Example"
        answer = { _ in .declined }
        let declined = await fill()
        XCTAssertTrue(declined.isError && declined.text.contains("chose not to save"), declined.text)
        XCTAssertEqual(vault.secret(of: item.id)?.oneTimeCode?.key, key)
        XCTAssertEqual(filledCodes.count, 1)

        // A page whose setup the vault holds asks nothing and fills its code.
        link = "otpauth://totp/Example:ada?secret=\(Base32.encode(key))&issuer=Example"
        answer = { _ in XCTFail("asked about a setup the vault holds"); return .declined }
        let held = await fill()
        XCTAssertFalse(held.isError || held.text.contains("saved the page's"), held.text)
        XCTAssertEqual(filledCodes.count, 2)
    }

    /// A key or token shows in no result, from a field that is not a password field too, and leaves no part of itself
    /// where a long text is cut; a screenshot is taken with it covered in each frame and the page put back after. Agents
    /// read it only once the person at this Mac turned that off.
    func testKeysAndTokensStayOutOfResultsUntilThePersonTurnsThatOff() async {
        // Made up, and built from parts so that no secret scanner takes it for a real token.
        let token = "xox" + "b-1111111111-2222222222222-" + String(repeating: "Fake", count: 6)
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                .object(["nodeId": .string("1"), "ignored": .bool(false), "role": .object(["value": .string("RootWebArea")]),
                         "name": .object(["value": .string("OAuth & Permissions")]), "childIds": .array([.string("2")]),
                         "backendDOMNodeId": .integer(1)]),
                .object(["nodeId": .string("2"), "parentId": .string("1"), "ignored": .bool(false),
                         "role": .object(["value": .string("textbox")]), "name": .object(["value": .string("Bot User OAuth Token")]),
                         "properties": .array([.object(["name": .string("readonly"), "value": .object(["value": .bool(true)])])]),
                         "value": .object(["value": .string(token)]), "childIds": .array([]), "backendDOMNodeId": .integer(12)])
            ])])
        }
        let snapshot = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(snapshot.text.contains("textbox \"Bot User OAuth Token\" [readonly]"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains(": \"xoxb-[hidden credential]\""), snapshot.text)
        XCTAssertFalse(snapshot.text.contains("1111"), snapshot.text)

        // The first 1,000 characters would end in the token's first digits, too few to read as one.
        cdp.bodyTexts = [String(repeating: "a", count: 990) + " " + token]
        let waited = await run(AgentToolCatalog.waitFor, ["text": .string("Saved"), "timeout": .number(0.05)])
        XCTAssertTrue(waited.text.contains("xoxb-[hid"), waited.text)
        XCTAssertFalse(waited.text.contains("1111"), waited.text)

        // The main frame shows the token and the frame in it shows none: the main frame's cover is released after.
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object(["cssVisualViewport": .object(["clientWidth": .number(800), "clientHeight": .number(600)])])
        }
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("iVBORw0KGgo=")]) }
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object(["id": .string("main")]),
                                           "childFrames": .array([.object(["frame": .object(["id": .string("ad")])])])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { params in
            XCTAssertEqual(params["worldName"], .string(BrowserAgentTools.vaultWorldName))
            return .object(["executionContextId": .integer(params["frameId"] == .string("main") ? 7 : 8)])
        }
        cdp.responders["Runtime.evaluate"] = { params in
            ScriptedCDP.value(params["contextId"].map { .integer($0 == .integer(7) ? 1 : 0) } ?? .number(1))
        }
        var mark = cdp.sent.count
        let captures = { [unowned self] in
            cdp.sent[mark...].compactMap { call -> String? in
                if call.method == "Page.captureScreenshot" { return "capture" }
                guard let context = call.params["contextId"]?.integerValue,
                      let expression = call.params["expression"]?.stringValue else { return nil }
                return (expression.contains(CredentialText.coverScript) ? "cover " : "release ") + String(context)
            }
        }
        let shot = await run(AgentToolCatalog.screenshot)
        XCTAssertFalse(shot.isError, shot.text)
        XCTAssertEqual(captures(), ["cover 7", "cover 8", "capture", "release 7"])
        XCTAssertTrue(cdp.params(of: "Runtime.evaluate").contains {
            $0["expression"]?.stringValue?.hasSuffix("(\(CredentialText.pageShapes), 60000)") == true
        }, "the page takes the same shapes, and puts itself back if no release comes")

        cdp.responders["Runtime.evaluate"] = { _ in ScriptedCDP.value(.string(token)) }
        let read = { await self.run(AgentToolCatalog.evaluate, ["function": .string("() => document.querySelector('input').value")]) }
        let hidden = await read()
        XCTAssertEqual(hidden.text, "\"xoxb-[hidden credential]\"")

        let secrets = InMemoryVaultSecretStore()
        func vault(confirming: Bool, teamSigned: Bool = true) -> VaultCenter {
            VaultCenter(environment: VaultCenter.Environment(
                secrets: secrets, repository: InMemoryVaultRepository(), hmac: MacVault.hmac,
                isAllowedBuild: teamSigned, confirm: { _ in confirming }, defaults: .vaultTests()))
        }
        let refused = vault(confirming: false)
        tools.vault = refused
        await refused.setHidesCredentials(false)
        XCTAssertTrue(refused.hidesCredentials, "not without the person's confirmation")
        let stillHidden = await read()
        XCTAssertEqual(stillHidden.text, hidden.text)
        let confirmed = vault(confirming: true)
        tools.vault = confirmed
        await confirmed.setHidesCredentials(false)
        XCTAssertFalse(confirmed.hidesCredentials)
        let shown = await read()
        XCTAssertEqual(shown.text, "\"\(token)\"")
        cdp.responders["Runtime.evaluate"] = { _ in ScriptedCDP.value(.number(1)) }
        mark = cdp.sent.count
        let shownShot = await run(AgentToolCatalog.screenshot)
        XCTAssertFalse(shownShot.isError, shownShot.text)
        XCTAssertEqual(captures(), ["capture"])
        XCTAssertFalse(vault(confirming: false).hidesCredentials, "kept for the next launch")
        XCTAssertTrue(vault(confirming: true, teamSigned: false).hidesCredentials,
                      "a build that is not team-signed always hides")
    }

    /// The kinds of keys the switch names, each with the prefix that tells its kind left, and words that only look a
    /// little like one left alone.
    func testCredentialTextHidesTheKeysServicesIssue() throws {
        // Made up, and built from parts so that no secret scanner takes them for real keys.
        let body = String(repeating: "A1b2", count: 10)
        let keys = [
            ("xox" + "b-123456789012-" + body, "xoxb-"), ("xox" + "e.xoxp-1-" + body, "xoxe.xoxp-"),
            ("xap" + "p-1-A0123-" + body, "xapp-"),
            ("https://hooks.slack" + ".com/services/T0000/B0000/" + body, "https://hooks.slack.com/services/"),
            ("gh" + "p_" + body, "ghp_"), ("github" + "_pat_11AAAA_" + body, "github_pat_"),
            ("sk" + "-proj-" + body, "sk-proj-"), ("sk" + "-ant-api03-" + body, "sk-ant-api03-"),
            ("sk" + "_live_" + body, "sk_live_"), ("rk" + "_live_" + body, "rk_live_"),
            ("AK" + "IA" + "ABCDEFGHIJ234567", "AKIA"), ("AI" + "za" + String(body.prefix(35)), "AIza")
        ]
        for (key, kind) in keys {
            XCTAssertEqual(CredentialText.scrub("Key: \(key)."), "Key: \(kind)[hidden credential].", kind)
        }
        let pem = "-----BEGIN RSA PRIVATE" + " KEY-----\n\(body)\n\(body)\n-----END RSA PRIVATE KEY-----"
        XCTAssertEqual(CredentialText.scrub(pem), "-----BEGIN RSA PRIVATE KEY-----[hidden credential]-----END RSA PRIVATE KEY-----")
        // A bearer token, a JSON Web Token, and a value given to a name a secret goes by, as typed and inside JSON's
        // escaped quotes; the name stays.
        let jwt = "ey" + "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0." + body
        let named = [
            ("Authorization: Bearer \(body).", "Authorization: Bearer [hidden credential]."),
            ("Here: \(jwt).", "Here: eyJ[hidden credential]."),
            ("export OPENAI_API_KEY=\(body).", "export OPENAI_API_KEY=[hidden credential]."),
            (#"{"apiKey": ""# + body + #""}"#, #"{"apiKey": "[hidden credential]"}"#),
            (#"{"answer":"Use password: "# + body + #"\nthen db_password = '"# + body + #"'"}"#,
             #"{"answer":"Use password: [hidden credential]\nthen db_password = '[hidden credential]'"}"#),
            (#"{"answer":"Set \"STRIPE_SECRET\": \""# + body + #"\""}"#,
             #"{"answer":"Set \"STRIPE_SECRET\": \"[hidden credential]\""}"#),
            ("GITHUB_TOKEN=gh" + "p_" + body, "GITHUB_TOKEN=ghp_[hidden credential]")
        ]
        for (text, hidden) in named {
            XCTAssertEqual(CredentialText.scrub(text), hidden)
        }
        let ordinary = "sk-learn, risk-assessment-2026-quarterly-report-final-v2, task_live_updates_2026, xoxo-hugs, AKIA. "
            + "Commit 3f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a3f, sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855, "
            + "task_key: 550e8400-e29b-41d4-a716-446655440000. max_tokens: 4096, sort_key=created_at_timestamp_desc, "
            + "PRIMARY_KEY=id, KEYCHAIN_PATH=/tmp/a1b2c3d4e5f6g7h8, apiKey: process.env.OPENAI_API_KEY, a bearer token, "
            + "Bearer tokens expire."
        XCTAssertEqual(CredentialText.scrub(ordinary), ordinary)
        let joined = String(repeating: "a-", count: 8_000)
        let started = ContinuousClock.now
        XCTAssertEqual(CredentialText.scrub(joined + "key"), joined + "key")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "A long run of joined words is read once")

        // A screenshot's page finds them with the same expressions in JavaScript (`CredentialText.pageShapes`).
        let context = try XCTUnwrap(JSContext())
        let holds = context.evaluateScript("""
            (() => {
              const shapes = \(CredentialText.pageShapes).map(([anchors, source]) => [anchors, new RegExp(source)]);
              return text => shapes.some(([anchors, pattern]) => anchors.some(a => text.includes(a)) && pattern.test(text));
            })()
            """)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        for (key, kind) in keys + [(pem, "PEM")] {
            XCTAssertEqual(holds?.call(withArguments: ["Key: \(key)."])?.toBool(), true, kind)
        }
        for (text, _) in named {
            XCTAssertEqual(holds?.call(withArguments: [text])?.toBool(), true, text)
        }
        XCTAssertEqual(holds?.call(withArguments: [ordinary])?.toBool(), false)
    }

    func testEvaluateWithAReferencePassesTheElement() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-15")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("Docs")) }
        let result = await run(AgentToolCatalog.evaluate, ["function": .string("(element) => element.textContent"), "ref": .string("@e4")])
        XCTAssertEqual(result.text, "\"Docs\"")
        let call = cdp.params(of: "Runtime.callFunctionOn").first
        XCTAssertEqual(call?["objectId"], .string("obj-15"))
        XCTAssertEqual(call?["arguments"], .array([.object(["objectId": .string("obj-15")])]))
    }

    // MARK: - Resize

    private var emulations: [BrowserViewportEmulation?] = []
    private var colorSchemes: [String?] = []

    func testResizeEmulatesPresetsAndCustomSizesKeepsTheColorSchemeApartAndRefusesHalfASize() async {
        page.emulate = { [unowned self] in emulations.append($0) }
        page.emulateColorScheme = { [unowned self] in colorSchemes.append($0) }

        let phone = await run(AgentToolCatalog.resize, ["preset": .string("mobile")])
        XCTAssertFalse(phone.isError, phone.text)
        XCTAssertTrue(phone.text.hasPrefix("Viewport set to 375x812 (mobile) on this tab"), phone.text)
        XCTAssertEqual(emulations.last, BrowserViewportEmulation(width: 375, height: 812, owner: .agent))
        XCTAssertEqual(emulations.last??.mobile, true)
        XCTAssertEqual(emulations.last??.deviceMetrics["deviceScaleFactor"], .integer(2))

        _ = await run(AgentToolCatalog.resize, ["width": .number(1000.4), "height": .integer(700)])
        XCTAssertEqual(emulations.last, BrowserViewportEmulation(width: 1000, height: 700, owner: .agent))
        XCTAssertEqual(emulations.last??.mobile, false, "768 and wider is not a phone")

        let desktop = await run(AgentToolCatalog.resize, ["preset": .string("desktop"), "colorScheme": .string("dark")])
        XCTAssertEqual(emulations.count, 3)
        XCTAssertNil(emulations.last ?? nil)
        XCTAssertEqual(colorSchemes, ["dark"])
        XCTAssertTrue(desktop.text.contains("cleared") && desktop.text.contains("Color scheme emulation set to dark"), desktop.text)

        page.emulation = { BrowserViewportEmulation(BrowserViewportEmulation.tablet, owner: .person) }
        let over = await run(AgentToolCatalog.resize, ["preset": .string("mobile")])
        XCTAssertTrue(over.text.contains("replaced the 768x1024 size the person picked"), over.text)

        for (arguments, error) in [(["width": JSONValue.integer(500)], "needs both width and height"),
                                   (["width": .integer(0), "height": .integer(10)], "needs both width and height"),
                                   (["preset": .string("watch")], "Unknown preset"),
                                   (["colorScheme": .string("sepia")], "Unknown colorScheme"),
                                   ([:], "Provide a preset")] {
            let refused = await run(AgentToolCatalog.resize, arguments)
            XCTAssertTrue(refused.isError && refused.text.contains(error), refused.text)
        }
        XCTAssertEqual(emulations.count, 4, "a refused call changes nothing")

        // The panel fits a larger size in, scaled down, across the middle and from the top; a smaller one is centered.
        let large = BrowserViewportEmulation.pageFrame(for: CGSize(width: 1600, height: 1000), in: CGSize(width: 659, height: 426))
        XCTAssertEqual(large.scale, 659.0 / 1600, accuracy: 0.0001)
        XCTAssertEqual(large.origin, .zero)
        let small = BrowserViewportEmulation.pageFrame(for: CGSize(width: 375, height: 812), in: CGSize(width: 659, height: 900))
        XCTAssertEqual(small.scale, 1)
        XCTAssertEqual(small.origin, CGPoint(x: 142, y: 0))
    }

    // MARK: - Batch

    func testBatchRunsInOrderAndStopsAtTheFirstFailure() async {
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_navigate"), "input": .object(["url": .string("https://example.com")])]),
            .object(["name": .string("browser_click"), "input": .object(["ref": .string("@e5")])]),
            .object(["name": .string("browser_snapshot")])
        ])])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.failure?.kind, .notFound, "the failed action's failure is the batch's")
        XCTAssertEqual(result.failure?.details["action"], .integer(2))
        XCTAssertTrue(result.text.hasPrefix("1. browser_navigate: Loaded https://example.com/"), result.text)
        XCTAssertTrue(result.text.contains("2. browser_click failed: There is no snapshot of tab 4 yet"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Stopped at action 2; 1 later action was not run."), result.text)
        XCTAssertFalse(cdp.methods.contains("Accessibility.getFullAXTree"), "Nothing after the failure runs")
    }

    func testBatchCarriesImagesAndRefusesNestingAndUnknownTools() async {
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object(["cssVisualViewport": .object(["clientWidth": .number(10), "clientHeight": .number(10)])])
        }
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("AAAA")]) }
        let shots = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_screenshot")]),
            .object(["name": .string("browser_wait_for"), "input": .object(["time": .number(0)])])
        ])])
        XCTAssertFalse(shots.isError, shots.text)
        XCTAssertEqual(shots.content.first, .image(data: "AAAA", mimeType: "image/png"))

        let nested = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_batch"), "input": .object(["actions": .array([])])])
        ])])
        XCTAssertTrue(nested.isError)
        XCTAssertTrue(nested.text.contains("cannot contain another batch"), nested.text)
        let unknown = await run(AgentToolCatalog.batch, ["actions": .array([.object(["name": .string("browser_fly")])])])
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.failure?.kind, .unknownTool)
        // Each action's input is checked against its tool's schema, as a call of its own is.
        let unchecked = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_wait_for"), "input": .object(["time": .number(0)])]),
            .object(["name": .string("browser_evaluate"), "input": .object(["script": .string("() => 1")])])
        ])])
        XCTAssertEqual(unchecked.failure?.kind, .invalidArguments)
        XCTAssertEqual(unchecked.failure?.details["action"], .integer(2))
        XCTAssertTrue(unchecked.text.contains("browser_evaluate was not run: it needs function. It takes no script."), unchecked.text)
        let empty = await run(AgentToolCatalog.batch, ["actions": .array([])])
        XCTAssertTrue(empty.isError)
    }

    // MARK: - Engine errors

    func testTheBrowserEnginesAbsenceAndCDPTimeoutsReadAsErrors() async {
        let unavailable = BrowserAgentTools(usesMacEditingCommands: false, pages: { _ in
            throw BrowserAgentToolError("This Yardlet build has no browser engine, so the browser tools are unavailable.")
        })
        let result = await unavailable.run(tool: AgentToolCatalog.snapshot, arguments: .object([:]), sessionID: UUID())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no browser engine"))

        cdp.responders["Accessibility.getFullAXTree"] = { _ in throw BrowserDevToolsError.timedOut("Accessibility.getFullAXTree") }
        let timedOut = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(timedOut.isError)
        XCTAssertEqual(timedOut.text, "The browser did not answer Accessibility.getFullAXTree within 15 seconds.")
    }

    func testAToolSaysWhenThePageOpenedANewTab() async {
        page.receive(.openedTab(tab: 4, newTab: 9, url: "https://b.test/"))
        page.receive(.openedTab(tab: 4, newTab: nil, url: "https://c.test/"))
        let result = await run(AgentToolCatalog.consoleMessages)
        let text = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        XCTAssertTrue(text.contains("The page opened https://b.test/ in a new tab (tabId \"9\")"), text)
        XCTAssertTrue(text.contains("https://c.test/ in place"), text)
        let next = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(next.content.contains { if case .text(let text) = $0 { text.contains("opened") } else { false } }, "said once")
    }
}
