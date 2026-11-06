import AppKit
@preconcurrency import IOSurface
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// Each browser tab a tab of the task's side panel, in the whole main window with the CEF panel's own
/// views over a stand-in browser host (no Chromium: pages are the host's events, frames none), light
/// and dark, into `.build/browser-panel-tabs-qa/<phase>/` (`BROWSER_PANEL_TABS_QA_PHASE`, "after" by
/// default), with what the strip shows at each step (`report.md`). Buttons are pressed through
/// accessibility and keys go to the page as the keyboard sends them. A handed tab is also drawn as another Mac's window
/// shows it over the remote (`remote-handoff-*`, beside this Mac's `local-handoff-*`), and a task's own tabs as that
/// window lists and shows them (`remote-task-opened`, `remote-panel-button`, `remote-new-tab`, `remote-file-page`,
/// `remote-file-address-refused`, `remote-agent-file-page`, `remote-saved-tab-shown`).
@MainActor
final class BrowserPanelTabsQATests: XCTestCase {
    private typealias Navigation = TaskSurfaceNavigationProjection
    private static let size = NSSize(width: 1280, height: 760)
    private static var folder: String {
        "browser-panel-tabs-qa/" + (ProcessInfo.processInfo.environment["BROWSER_PANEL_TABS_QA_PHASE"] ?? "after")
    }

    /// The browser host as the panel sees it: tabs open, and the test reports their pages.
    private final class StandInHost: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        /// Answers the remote's picture of a tab (docs/REMOTE_PROTOCOL.md §15.25) with the page `picture` draws at the
        /// tab's size, as Chromium would picture what it shows.
        var picture: ((_ width: Double, _ height: Double) -> Data?)?
        private var viewports: [BrowserTabID: BrowserViewport] = [:]
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            if case .resize(let tab, let viewport) = command { viewports[tab] = viewport }
            if case .open(let tab, _, let viewport, _) = command { viewports[tab] = viewport }
            if let picture, case .devTools(let tab, let message) = command,
               let object = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)),
               let id = object["id"]?.integerValue, let method = object["method"]?.stringValue {
                let viewport = viewports[tab] ?? .offscreenDefault
                let result: String = switch method {
                case "Page.getLayoutMetrics":
                    #"{"cssVisualViewport":{"clientWidth":\#(viewport.width),"clientHeight":\#(viewport.height),"pageX":0,"pageY":0}}"#
                case "Runtime.evaluate": #"{"result":{"type":"number","value":\#(viewport.scale)}}"#
                case "Page.captureScreenshot":
                    #"{"data":"\#(picture(viewport.width, viewport.height)?.base64EncodedString() ?? "")"}"#
                default: "{}"
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: #"{"id":\#(id),"result":\#(result)}"#)) }
                }
            }
            // A person's close asks the page first (2026-10-25); these pages do not ask, so the host closes the
            // tab and says so, as Chromium does.
            if case .requestClose(let tab) = command {
                DispatchQueue.main.async { self.eventHandler?(.closed(tab: tab)) }
            }
        }
        func terminate() { eventHandler?(.terminated(reason: "signal 15")) }

        var opened: [(tab: BrowserTabID, url: String)] {
            sent.compactMap { if case .open(let tab, let url, _, _) = $0 { (tab, url) } else { nil } }
        }
        /// The tabs asked to close, once each: a person's close is a request, and the client's own close
        /// follows when the host says the tab closed.
        var closed: [BrowserTabID] {
            var seen = Set<BrowserTabID>()
            return sent.compactMap {
                switch $0 {
                case .close(let tab), .requestClose(let tab): seen.insert(tab).inserted ? tab : nil
                default: nil
                }
            }
        }

        func load(_ tab: BrowserTabID, _ url: String, title: String, icon: Data? = nil) {
            eventHandler?(.loading(tab: tab, isLoading: true, canGoBack: false, canGoForward: false))
            eventHandler?(.address(tab: tab, url: url))
            eventHandler?(.title(tab: tab, title: title))
            if let icon { eventHandler?(.favicon(tab: tab, url: url + "icon.png", png: icon)) }
            eventHandler?(.loading(tab: tab, isLoading: false, canGoBack: false, canGoForward: false))
        }
    }

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let legacy: SessionRecord
        let host: () -> StandInHost?
        let client: BrowserHostClient
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-browser-panel-tabs-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("BrowserPanelTabsQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = root.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let task = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                 title: "Fix the sign-in screen")
        let legacy = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                   title: "Browser tab from an earlier build")
        let sessions = [task, legacy]
        // A task saved by a build before side-panel browser tabs: one Browser tab holding three.
        defaults.set(Data(#"""
        {"version":1,"panelsRevision":2,
         "panels":{"trailingSurfaceID":"browser","isTerminalPresented":false,
                   "trailingTabs":["browser"],"recentTrailingTabs":["browser"]},
         "layout":{"panelWidth":420,"terminalHeight":280,"isExpanded":false},
         "transcript":{"fraction":0,"followsLatest":true},"codex":{"fraction":0,"followsLatest":true},
         "browser":{"address":"http://localhost:3000/","tabs":["https://docs.test/","http://localhost:3000/","https://status.test/"],"selectedTab":1}}
        """#.utf8), forKey: "Yardlet.taskWorkspace.\(legacy.id.uuidString)")
        var host: StandInHost?
        let client = BrowserHostClient(idleGrace: .seconds(60)) {
            let started = StandInHost()
            host = started
            return started
        }
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in Recorder() },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            taskWorkspaceRepository: UserDefaultsTaskWorkspaceRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false,
            browserClient: { client }
        )
        addTeardownBlock { await model.shutdown() }
        _ = model.projects.ensureProject(forRoot: folder)
        return Fixture(model: model, task: task, legacy: legacy, host: { host }, client: client)
    }

    private func window(_ fixture: Fixture, _ appearance: WindowlessRender.Appearance, size: NSSize = size) -> some View {
        MainWindow(model: fixture.model)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    // MARK: - Accessibility and keys

    private struct Control {
        let role: String
        let label: String
        let frame: NSRect
        let object: AnyObject
    }

    private func controls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        host.hosting.layoutSubtreeIfNeeded()
        let windowFrame = host.window.frame
        return WindowlessRender.withAccessibilityTree {
            var found: [Control] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if let role = child.accessibilityRole?() ?? nil,
                       [.button, .menuButton, .popUpButton].contains(role) {
                        let screen = child.accessibilityFrame?() ?? .zero
                        let frame = NSRect(x: screen.minX - windowFrame.minX, y: windowFrame.maxY - screen.maxY,
                                           width: screen.width, height: screen.height)
                        if frame.height > 0 {
                            found.append(Control(role: role.rawValue, label: (child.accessibilityLabel?() ?? nil) ?? "",
                                                 frame: frame, object: child))
                        }
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    /// The side panel's tab strip: its buttons in the title bar's row, which the panel reaches since the
    /// one-row header (2026-10-24), right of the conversation, left to right.
    private func strip<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        controls(in: host)
            .filter { $0.frame.maxY <= ParityTheme.titleBarHeight && $0.frame.minX > Self.size.width / 2 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    @discardableResult
    private func press<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>,
                                      among pool: [Control]? = nil) -> Bool {
        guard let control = (pool ?? controls(in: host)).first(where: { $0.label == label }) else { return false }
        let pressed = WindowlessRender.withAccessibilityTree { control.object.accessibilityPerformPress?() ?? false }
        host.settle(passes: 12, interval: 0.03)
        return pressed
    }

    private func orderIn<Content: View>(_ host: WindowlessRender.Host<Content>) {
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 10, interval: 0.03)
    }

    private func browserView(in view: NSView) -> BrowserHostView? {
        if let view = view as? BrowserHostView { return view }
        for subview in view.subviews {
            if let found = browserView(in: subview) { return found }
        }
        return nil
    }

    /// A key on the page, as the keyboard sends it: the page has the keyboard, so the panel's page keys
    /// go first.
    @discardableResult
    private func pageKey<Content: View>(_ character: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                                        in host: WindowlessRender.Host<Content>) -> Bool {
        guard let page = browserView(in: host.hosting) else { return false }
        host.window.makeFirstResponder(page)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: host.window.windowNumber, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: keyCode) else { return false }
        let handled = host.window.performKeyEquivalent(with: event)
        host.settle(passes: 12, interval: 0.03)
        return handled
    }

    private func waitUntil<Content: View>(_ host: WindowlessRender.Host<Content>, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            host.settle(passes: 1, interval: 0.03)
        }
        return condition()
    }

    // MARK: - Report

    private var report: [String] = []
    private var recordsReport = true

    private func describe(_ state: String, _ controls: [Control], notes: [String] = []) {
        guard recordsReport else { return }
        report.append("## \(state)")
        report.append("")
        report.append(contentsOf: controls.isEmpty ? ["- (no buttons)"]
                      : controls.map { "- \($0.label.isEmpty ? "(no name)" : $0.label) [\($0.role)]" })
        for note in notes { report.append("- Check: \(note)") }
        report.append("")
    }

    private func draw<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                     _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    // MARK: - States

    func testEachBrowserTabIsASidePanelTab() throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            recordsReport = appearance == .light
            try browserTabs(appearance)
        }
        let directory = try WindowlessRender.directory(Self.folder)
        try (["# Browser tabs in the right panel", ""] + report).joined(separator: "\n")
            .write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
    }

    /// A page that does not respond (Chromium's hang monitor, read by the host): Chrome's "Page
    /// Unresponsive" with Wait and Reload above the page, "Not responding" first in the header; Wait waits,
    /// Reload opens the page again in its place under the same side-panel tab.
    func testAPageThatDoesNotRespond() throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            let fixture = try makeFixture()
            let model = fixture.model
            let client = fixture.client
            let task = fixture.task
            let workspace = model.taskWorkspaces.state(for: task.id)
            model.splits.activate(.session(task.id))
            let host = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
            orderIn(host)
            defer { host.close() }
            XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
            XCTAssertTrue(press(L10n.string("Browser"), in: host))
            let key = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
            XCTAssertTrue(waitUntil(host) { client.tab(key: key, forSession: task.id) != nil })
            let tab = try XCTUnwrap(client.tab(key: key, forSession: task.id))
            let standIn = try XCTUnwrap(fixture.host())
            standIn.load(tab.id, "http://localhost:3100/erp/review", title: "ERPNext review")
            host.settle(passes: 8, interval: 0.03)

            // The page keeps its size through a load: each resize lays it out again.
            func resizes() -> Int { standIn.sent.filter { if case .resize = $0 { true } else { false } }.count }
            let resized = resizes()
            standIn.eventHandler?(.loading(tab: tab.id, isLoading: true, canGoBack: false, canGoForward: false))
            host.settle(passes: 6, interval: 0.03)
            standIn.eventHandler?(.loading(tab: tab.id, isLoading: false, canGoBack: false, canGoForward: false))
            host.settle(passes: 6, interval: 0.03)
            XCTAssertEqual(resizes(), resized, "before, the loading row resized the page")

            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: false))
            host.settle(passes: 10, interval: 0.03)
            func barButton(_ label: String) -> Control? {
                controls(in: host).filter { $0.label == label }.max { $0.frame.minY < $1.frame.minY }
            }
            XCTAssertNotNil(barButton(L10n.string("Wait")), "Chrome's Wait")
            try draw(host, "page-unresponsive", appearance)

            let wait = try XCTUnwrap(barButton(L10n.string("Wait")))
            let sentBefore = standIn.sent.count
            XCTAssertTrue(WindowlessRender.withAccessibilityTree { wait.object.accessibilityPerformPress?() ?? false })
            host.settle(passes: 10, interval: 0.03)
            // The page takes the bar's room back as the bar goes, so a resize follows.
            XCTAssertTrue(standIn.sent.dropFirst(sentBefore).contains(.unresponsive(tab: tab.id, action: .wait)))
            XCTAssertNil(barButton(L10n.string("Wait")), "Wait hides it for 15 seconds")

            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: true))
            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: false))
            host.settle(passes: 10, interval: 0.03)
            let reload = try XCTUnwrap(barButton(L10n.string("Reload")))
            XCTAssertTrue(WindowlessRender.withAccessibilityTree { reload.object.accessibilityPerformPress?() ?? false })
            host.settle(passes: 12, interval: 0.03)
            let replacement = try XCTUnwrap(client.tab(key: key, forSession: task.id))
            XCTAssertFalse(replacement === tab, "the stuck page's tab was replaced")
            XCTAssertTrue(standIn.closed.contains(tab.id))
            XCTAssertEqual(standIn.opened.last?.url, "http://localhost:3100/erp/review")
            XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(key), "the same side-panel tab")
            XCTAssertNil(barButton(L10n.string("Wait")))
            standIn.load(replacement.id, "http://localhost:3100/erp/review", title: "ERPNext review")
            host.settle(passes: 8, interval: 0.03)
            try draw(host, "page-reloaded", appearance)
        }
    }

    /// The panel's bars (the agent's handoff, a site's permission question, the password manager's offers, the panel's
    /// notice) sit above the page and take their room from it, as Chrome's infobars do: the top of a sign-in page, with
    /// its Sign in button, stays in view and takes the clicks with one bar and with six, in a window of the usual height
    /// and of the least, where six take half the room and scroll (`bars-*`, light and dark, and `bars.md`). The notice
    /// closes. Until 2026-11-02 the bars lay over the page's top.
    func testBarsTakeTheirRoomAboveThePage() throws {
        report = ["# Bars above the browser page", ""]
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            recordsReport = appearance == .light
            try bars(appearance, size: Self.size, name: "bars")
            // MainWindow's least height.
            try bars(appearance, size: NSSize(width: Self.size.width, height: 560), name: "bars-short")
        }
        try report.joined(separator: "\n")
            .write(to: try WindowlessRender.directory(Self.folder).appending(path: "bars.md"), atomically: true, encoding: .utf8)
    }

    private func bars(_ appearance: WindowlessRender.Appearance, size: NSSize, name: String) throws {
        let fixture = try makeFixture()
        let model = fixture.model, task = fixture.task, client = fixture.client
        let workspace = model.taskWorkspaces.state(for: task.id)
        model.splits.activate(.session(task.id))
        let host = WindowlessRender.Host(window(fixture, appearance, size: size), size: size, appearance: appearance)
        orderIn(host)
        defer { host.close() }
        XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
        XCTAssertTrue(press(L10n.string("Browser"), in: host))
        let key = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertTrue(waitUntil(host) { client.tab(key: key, forSession: task.id) != nil })
        let tab = try XCTUnwrap(client.tab(key: key, forSession: task.id))
        let standIn = try XCTUnwrap(fixture.host())
        let address = "https://console.example.test/signin"
        standIn.load(tab.id, address, title: "Sign in")
        host.settle(passes: 8, interval: 0.03)
        let page = try XCTUnwrap(browserView(in: host.hosting))
        let controller = try XCTUnwrap(BrowserHostPaneController.current)

        /// The page's frame in the window, from its top left.
        func pageFrame() -> NSRect {
            let frame = page.convert(page.bounds, to: nil)
            return NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
        }
        func lastViewportHeight() -> Double? {
            standIn.sent.reversed().lazy.compactMap { if case .resize(_, let viewport) = $0 { viewport.height } else { nil } }.first
        }
        /// A click at this point of the page (from its top left) reaches the page.
        func reaches(_ point: NSPoint, in frame: NSRect) -> Bool {
            let inWindow = NSPoint(x: frame.minX + point.x, y: size.height - (frame.minY + point.y))
            var hit = host.hosting.hitTest(host.hosting.superview?.convert(inWindow, from: nil) ?? inWindow)
            while let view = hit, view !== page { hit = view.superview }
            return hit != nil
        }
        let barLabels = ["I'm done", "Decline", "Wait", "Block", "Allow", "Not Now", "Use Strong Password", "Save"]
            .map(L10n.string)
        var sequence: UInt64 = 0
        func state(_ state: String) throws -> (page: NSRect, bars: [Control]) {
            host.settle(passes: 10, interval: 0.03)
            sequence += 1
            showSignInPage(in: page, sequence: sequence)
            host.settle(passes: 2, interval: 0.03)
            try draw(host, "\(name)-\(state)", appearance)
            let frame = pageFrame()
            // The bars' buttons in view: those a short window's bars scroll away lie under the bars' bottom edge.
            let shown = controls(in: host).filter { barLabels.contains($0.label) && $0.frame.minX >= frame.minX && $0.frame.minY < frame.minY }
            // The page's top row and its Sign in button take the clicks.
            let top = [0.05, 0.5, 0.95].map { NSPoint(x: frame.width * $0, y: 2) } + [NSPoint(x: frame.width - 62, y: 28)]
            let reached = top.filter { reaches($0, in: frame) }.count
            describe("\(name) \(Int(size.height)) pt, \(state)", shown, notes: [
                "page top \(Int(frame.minY)) pt, height \(Int(frame.height)) pt, viewport sent \(lastViewportHeight().map { Int($0) } ?? 0) pt",
                "clicks at the page's top row and its Sign in button that reach the page: \(reached) of \(top.count)"
            ])
            XCTAssertEqual(reached, top.count, "\(name)-\(state): something lies over the page's top")
            XCTAssertEqual(lastViewportHeight(), frame.height.rounded(), "\(name)-\(state): the page is told its size")
            return (frame, shown)
        }

        let none = try state("none")
        _ = tab.handOff(reason: "Sign in to the console with your security key, then press I'm done.")
        let one = try state("one")
        XCTAssertLessThan(one.page.height, none.page.height, "\(name): the handoff bar takes its room from the page")
        XCTAssertEqual(Set(one.bars.map(\.label)), Set(["I'm done", "Decline"].map(L10n.string)))

        standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: false))
        standIn.eventHandler?(.permissionPrompt(tab: tab.id, prompt: BrowserPermissionPrompt(
            id: 1, origin: "https://console.example.test", permissions: ["notifications"])))
        controller.vaultPasswordOffer = BrowserVaultPasswordOffer(origin: "https://console.example.test", page: address)
        controller.walletSaveOffer = BrowserWalletSaveOffer(address: VaultAddress(
            name: "Jordan Park", street: "100 Example Street", city: "Springfield", region: "IL", postalCode: "62701", country: "US"))
        controller.showVaultNotice(L10n.string("The next passkey this site makes is saved in the password manager."),
                                   for: .seconds(120))
        let several = try state("several")
        XCTAssertLessThan(several.page.height, one.page.height, "\(name): each bar takes its room from the page")
        let half = (none.page.height / 2).rounded(.down)
        XCTAssertGreaterThanOrEqual(several.page.height, none.page.height - half, "\(name): the bars leave the page half the room")
        if size.height < Self.size.height {
            XCTAssertEqual(several.page.height, none.page.height - half, "\(name): six bars take half the room and scroll")
        }
        // In the order they come, the agent's handoff first.
        XCTAssertEqual(several.bars.min { $0.frame.minY < $1.frame.minY }.map(\.label), L10n.string("Decline"))

        // The notice, the last bar, closes, and the page takes its room back.
        if let close = controls(in: host).filter({ $0.label == L10n.string("Close") && $0.frame.minX >= several.page.minX })
            .max(by: { $0.frame.minY < $1.frame.minY }) {
            XCTAssertTrue(WindowlessRender.withAccessibilityTree { close.object.accessibilityPerformPress?() ?? false })
            let closed = try state("notice-closed")
            XCTAssertNil(controller.notice)
            XCTAssertGreaterThanOrEqual(closed.page.height, several.page.height)
        } else {
            XCTFail("\(name): the notice has no Close")
        }

        controller.answerHandoff(.done)
        standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: true))
        standIn.eventHandler?(.permissionPromptDismissed(tab: tab.id, prompt: 1))
        controller.vaultPasswordOffer = nil
        controller.walletSaveOffer = nil
        let after = try state("answered")
        XCTAssertEqual(after.page, none.page, "\(name): with the bars gone the page has its room back")
    }

    /// A tab the agent handed to the person, in this Mac's panel and in the window another Mac opens for this one over the
    /// remote (docs/REMOTE_PROTOCOL.md §15.25), both drawn: the same page, the handoff's bar with the same answers, the
    /// task's tab in the strip, Back, Forward and Reload, and the address. The remote's page is the host's picture of it,
    /// and its I'm done answers the handoff here.
    func testAHandedTabDrawsOnAnotherMacAsInThisMacsPanel() async throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            let fixture = try makeFixture()
            let model = fixture.model, task = fixture.task, client = fixture.client
            let workspace = model.taskWorkspaces.state(for: task.id)
            model.splits.activate(.session(task.id))
            let local = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
            orderIn(local)
            XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: local))
            XCTAssertTrue(press(L10n.string("Browser"), in: local))
            let key = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
            try await settle(local) { client.tab(key: key, forSession: task.id) != nil }
            let tab = try XCTUnwrap(client.tab(key: key, forSession: task.id))
            let standIn = try XCTUnwrap(fixture.host())
            standIn.picture = { width, height in Self.signInPicture(size: NSSize(width: width, height: height)) }
            standIn.load(tab.id, "https://console.example.test/signin", title: "Sign in")
            let reason = "Sign in to the console with your security key, then press I'm done."
            _ = tab.handOff(reason: reason)
            model.browserHandoffWaits[task.id] = [BrowserHandoffWait(notice: "handoff-render", tabKey: key, reason: reason)]
            try await settle(local) { false }
            let page = try XCTUnwrap(browserView(in: local.hosting))
            showSignInPage(in: page, sequence: 1)
            try await settle(local) { false }
            try draw(local, "local-handoff", appearance)
            let localBitmap = try local.capture().bitmap
            let localBar = controls(in: local).filter { ["I'm done", "Decline"].map(L10n.string).contains($0.label) }
            XCTAssertEqual(Set(localBar.map(\.label)), Set(["I'm done", "Decline"].map(L10n.string)))
            local.close()

            // This Mac as a host, followed by another Mac's window on loopback.
            let mac = try await anotherMac(fixture, port: 47876)
            defer { mac.close() }
            let remote = mac.remote, hosts = mac.hosts
            try await waitUntilAsync { remote.hasSnapshot && remote.task(task.id.uuidString) != nil }
            XCTAssertTrue(remote.offersBrowser)
            remote.select(.task(task.id.uuidString))
            let conversation = try XCTUnwrap(remote.conversations[task.id.uuidString])
            try await waitUntilAsync { conversation.presentation.turns.last?.requests.isEmpty == false }
            let request = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
            let show = try XCTUnwrap(request.responses.first { $0.title == L10n.string("Show Tab") })
            remote.respond(taskID: task.id.uuidString, requestID: request.id, route: show.route)
            try await waitUntilAsync { remote.browser.frame != nil && remote.browser.watchedTab?.requestId != nil }
            XCTAssertEqual(remote.browser.watchedTab?.title, "Sign in")
            XCTAssertEqual(tab.isRemotelyWatched, true)

            let window = WindowlessRender.Host(RemoteHostView(model: remote, directory: hosts)
                .frame(width: Self.size.width, height: Self.size.height)
                .environment(\.colorScheme, appearance.colorScheme), size: Self.size, appearance: appearance)
            orderIn(window)
            try await settle(window) { false }
            try draw(window, "remote-handoff", appearance)
            let remoteBitmap = try window.capture().bitmap
            let pair = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: localBitmap.pixelsWide + remoteBitmap.pixelsWide,
                pixelsHigh: max(localBitmap.pixelsHigh, remoteBitmap.pixelsHigh), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pair)
            localBitmap.draw(in: NSRect(x: 0, y: 0, width: localBitmap.pixelsWide, height: localBitmap.pixelsHigh))
            remoteBitmap.draw(in: NSRect(x: localBitmap.pixelsWide, y: 0, width: remoteBitmap.pixelsWide, height: remoteBitmap.pixelsHigh))
            NSGraphicsContext.restoreGraphicsState()
            try WindowlessRender.writePNG(pair, to: try WindowlessRender.directory(Self.folder)
                .appending(path: "browser-controls-pair-\(appearance.suffix).png"))
            // With the handed tab in the panel, the request is the panel's bar alone, as on this Mac: no card.
            let answers = ["I'm done", "Decline"].map(L10n.string)
            let remoteBar = controls(in: window).filter { answers.contains($0.label) }
            XCTAssertEqual(remoteBar.count, 2, "the bar's answers only: \(remoteBar.map(\.label))")
            XCTAssertFalse(controls(in: window).contains { $0.label == L10n.string("Show Tab") })
            XCTAssertTrue(controls(in: window).contains { $0.label == L10n.string("Reload") })
            // The panel closed, the card comes back with its Show Tab.
            remote.browser.hide()
            try await settle(window) { controls(in: window).contains { $0.label == L10n.string("Show Tab") } }
            XCTAssertEqual(controls(in: window).filter { answers.contains($0.label) }.count, 2, "the card's answers")
            try draw(window, "remote-handoff-card", appearance)
            remote.showBrowser(taskID: task.id.uuidString, tabID: key.uuidString)
            try await waitUntilAsync { remote.browser.frame != nil }
            try await settle(window) { !controls(in: window).contains { $0.label == L10n.string("Show Tab") } }

            // The bar's I'm done answers the handoff on this Mac.
            let done = try XCTUnwrap(controls(in: window).filter { $0.label == L10n.string("I'm done") }.first)
            XCTAssertTrue(WindowlessRender.withAccessibilityTree { done.object.accessibilityPerformPress?() ?? false })
            try await waitUntilAsync { tab.handoff?.answer == .done }
            // The address and close travel through the authenticated connection to this task's browser.
            XCTAssertTrue(remote.browser.canControlTabs)
            let priorCount = client.tabs(forSession: task.id).count
            XCTAssertTrue(remote.openHostBrowserLink(URL(string: "http://localhost:3000/preview")!, taskID: task.id.uuidString))
            try await NativeHarnessClientTests.waitUntil { client.tabs(forSession: task.id).count == priorCount + 1 }
            let opened = try XCTUnwrap(client.tab(forSession: task.id))
            standIn.load(opened.id, "http://localhost:3000/preview", title: "Preview")
            try await NativeHarnessClientTests.waitUntil { remote.browser.tabID == opened.key.uuidString }
            remote.browser.openAddress("localhost:4000/next")
            try await NativeHarnessClientTests.waitUntil { standIn.sent.contains(.navigate(tab: opened.id, url: "http://localhost:4000/next")) }
            // With the panel off the browser, a tab closed from the strip closes on the host, opens no panel, and leaves
            // the list the window follows.
            window.close()
            remote.browser.hide()
            let openedID = "browser:" + opened.key.uuidString
            XCTAssertTrue(remote.browser.surfaceTabs(for: task.id.uuidString).contains { $0.id == openedID })
            remote.browser.closeSurfaceTab(openedID, taskID: task.id.uuidString)
            try await NativeHarnessClientTests.waitUntil { client.tabs(forSession: task.id).count == priorCount }
            try await waitUntilAsync { !remote.browser.surfaceTabs(for: task.id.uuidString).contains { $0.id == openedID } }
            XCTAssertNil(remote.browser.taskID, "closing a background tab does not open its panel")
            XCTAssertTrue(standIn.closed.contains(opened.id))
            try await waitUntilAsync { !tab.isRemotelyWatched }
        }
    }

    /// A host task's own tabs in the window another Mac opens for this one (docs/REMOTE_PROTOCOL.md §15.25 and §18): the
    /// side panel's button shows the host's front tab and its picture, as this Mac's button shows the
    /// task's tab, with the task's tabs in the strip; a file page outside the task's files says it shows on the host
    /// alone rather than waiting for a picture that does not come, its address typed here is refused with why, and once
    /// the task's agent opens it in that tab it shows; a new tab from the panel joins them; and a task whose
    /// tabs were saved before Yardlet restarted lists them as the task opens, without starting the browser engine.
    func testAHostTasksOwnTabsShowOnAnotherMac() async throws {
        let fileTitle = BrowserTabTitle.make(pageTitle: "", address: "file://")
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            let fixture = try makeFixture()
            let task = fixture.task, legacy = fixture.legacy, client = fixture.client
            let mac = try await anotherMac(fixture, port: 47877)
            defer { mac.close() }
            let remote = mac.remote
            try await waitUntilAsync { remote.hasSnapshot && remote.task(legacy.id.uuidString) != nil }
            XCTAssertTrue(remote.offersBrowser)
            let window = WindowlessRender.Host(RemoteHostView(model: remote, directory: mac.hosts)
                .frame(width: Self.size.width, height: Self.size.height)
                .environment(\.colorScheme, appearance.colorScheme), size: Self.size, appearance: appearance)
            orderIn(window)
            defer { window.close() }

            // The task whose three tabs an earlier Yardlet saved: listed as it opens, none opened, no engine started.
            remote.select(.task(legacy.id.uuidString))
            try await settle(window) { remote.browser.tabs(for: legacy.id.uuidString).count == 3 }
            XCTAssertEqual(remote.browser.tabs(for: legacy.id.uuidString).map(\.url),
                           ["https://docs.test/", "http://localhost:3000/", "https://status.test/"], "saved tabs listed")
            let saved = remote.browser.tabs(for: legacy.id.uuidString)
            let savedFront = saved.first { $0.active == true }
            XCTAssertEqual(savedFront?.url, "http://localhost:3000/", "the tab saved in front")
            XCTAssertNil(fixture.host(), "listing the saved tabs starts no browser engine")
            XCTAssertNil(remote.browser.taskID, "no tab watched, so none painted")

            // The task the agent opened two tabs in on this Mac, its panel closed here: a page, and a file page outside
            // its folders (the agent's scratch page).
            let page = try client.newTab(forSession: task.id, url: "https://bookings.example.test/42",
                                         viewport: .offscreenDefault, select: true)
            let scratchAddress = "file:///private/tmp/agent-scratch/queue.html"
            let scratch = try client.newTab(forSession: task.id, url: scratchAddress, viewport: .offscreenDefault, select: false)
            let standIn = try XCTUnwrap(fixture.host())
            standIn.picture = { width, height in Self.signInPicture(size: NSSize(width: width, height: height)) }
            standIn.load(page.id, "https://bookings.example.test/42", title: "Booking 42")
            standIn.load(scratch.id, scratchAddress, title: "Posting queue")
            remote.select(.task(task.id.uuidString))
            try await settle(window) { remote.browser.tabs(for: task.id.uuidString).count == 2 }
            XCTAssertEqual(remote.browser.tabs(for: task.id.uuidString).map(\.url),
                           ["https://bookings.example.test/42", "file://"])
            try draw(window, "remote-task-opened", appearance)

            // The panel's button shows the host's front tab and its picture, the task's tabs in the strip.
            XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: window))
            try await waitUntilAsync { remote.browser.tabID == page.key.uuidString && remote.browser.frame != nil }
            try await settle(window) { strip(in: window).contains { $0.label == fileTitle } }
            XCTAssertEqual(remote.browser.watchedTab?.title, "Booking 42")
            XCTAssertTrue(strip(in: window).contains { $0.label == fileTitle }, "\(strip(in: window).map(\.label))")
            XCTAssertTrue(page.isRemotelyWatched)
            XCTAssertFalse(scratch.isRemotelyWatched)
            try draw(window, "remote-panel-button", appearance)
            describe("Another Mac: the side panel's button on a task with two host tabs", strip(in: window), notes: [
                "The host's front tab (Booking 42) shows with its picture; the file page outside the task is listed as \(fileTitle)"
            ])

            // A new tab from the strip's + (its menu's Browser, which this QA does not open) opens on the host and joins
            // the task's tabs.
            remote.browser.newSurfaceTab(taskID: task.id.uuidString)
            try await waitUntilAsync { client.tabs(forSession: task.id).count == 3 }
            let opened = try XCTUnwrap(client.tab(forSession: task.id))
            try await waitUntilAsync { remote.browser.tabID == opened.key.uuidString && remote.browser.frame != nil }
            try await settle(window) { strip(in: window).count >= 3 }
            try draw(window, "remote-new-tab", appearance)

            // The file page outside the task's files: said, not waited for.
            XCTAssertTrue(press(fileTitle, in: window, among: strip(in: window)))
            try await waitUntilAsync { remote.browser.tabID == scratch.key.uuidString && remote.browser.isListed }
            try await settle(window) { false }
            let notice = L10n.format("This page shows only on %@.", remote.name)
            let said = window.accessibilityElements().flatMap { [$0.label, $0.value] }
            XCTAssertTrue(said.contains(notice), "\(said.suffix(12))")
            try draw(window, "remote-file-page", appearance)

            // Its address typed here stays the host's to open, and the panel's bar says why.
            remote.browser.openAddress(scratchAddress)
            let refusal = L10n.format("Files outside this task's folders open only on %@.", remote.name)
            try await waitUntilAsync { remote.browser.refusal == refusal }
            try await settle(window) { false }
            try draw(window, "remote-file-address-refused", appearance)
            remote.browser.refusal = nil

            // The agent opens that file in its tab (browser_navigate tells the tab, then the page loads): it shows here.
            standIn.picture = { width, height in Self.queuePicture(size: NSSize(width: width, height: height)) }
            scratch.noteAgentOpened(scratchAddress)
            standIn.load(scratch.id, scratchAddress, title: "Posting queue")
            try await waitUntilAsync { remote.browser.watchedTab?.url == scratchAddress && remote.browser.frame != nil }
            try await settle(window) { false }
            XCTAssertEqual(remote.browser.watchedTab?.title, "Posting queue")
            XCTAssertFalse(window.accessibilityElements().flatMap { [$0.label, $0.value] }.contains(notice))
            try draw(window, "remote-agent-file-page", appearance)

            // Back on the task with saved tabs, the panel's button opens its front tab on the host and shows it.
            remote.select(.task(legacy.id.uuidString))
            try await settle(window) { remote.browser.taskID == legacy.id.uuidString }
            if remote.browser.taskID != legacy.id.uuidString {
                XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: window))
            }
            try await waitUntilAsync { client.tabs(forSession: legacy.id).count == 3 && remote.browser.frame != nil }
            XCTAssertEqual(remote.browser.tabID, savedFront?.tabId, "the tab saved in front, under its key")
            // The stand-in reports the restored pages as Chromium would.
            for tab in client.tabs(forSession: legacy.id) {
                let listed = saved.first { $0.tabId == tab.key.uuidString }
                standIn.load(tab.id, listed?.url ?? "", title: listed?.tabId == savedFront?.tabId ? "Login — Dev" : "")
            }
            try await settle(window) { remote.browser.watchedTab?.title == "Login — Dev" }
            try draw(window, "remote-saved-tab-shown", appearance)
        }
    }

    private struct AnotherMac {
        let hosts: RemoteHostDirectory
        let remote: RemoteHostModel
        let close: () -> Void
    }

    /// This Mac as a host on loopback, and another Mac's window paired with it.
    private func anotherMac(_ fixture: Fixture, port: UInt16) async throws -> AnotherMac {
        let client = fixture.client
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(
            model: fixture.model, browser: RemoteTabBridge.Environment(client: { client })), port: port)
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let remote = try XCTUnwrap(hosts.model(for: paired.id))
        return AnotherMac(hosts: hosts, remote: remote, close: { hosts.close(paired.id); stack.stop() })
    }

    /// Lays the window out and gives the main actor back between passes, until `condition` holds or about half a second
    /// passed: an async test holds the main queue, which the window's own settling alone does not drain.
    private func settle<Content: View>(_ host: WindowlessRender.Host<Content>, until condition: () -> Bool) async throws {
        for _ in 0..<20 {
            host.settle(passes: 1, interval: 0.01)
            try await Task.sleep(for: .milliseconds(20))
            if condition() { return }
        }
    }

    private func waitUntilAsync(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + testWaitLimit
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A sign-in page as the host would draw it at the page's size: a header with Sign in at its top right, a heading,
    /// a field and Next, so a render shows whether anything lies over the page's top.
    private func showSignInPage(in view: BrowserHostView, sequence: UInt64) {
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0, let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241
        ] as CFDictionary) else { return }
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard let context = CGContext(
            data: IOSurfaceGetBaseAddress(surface), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        Self.drawSignInPage(in: context, size: view.bounds.size, scale: scale)
        view.frameDisplay.show(BrowserFrame(layer: .view, surface: sequence, pixelWidth: width, pixelHeight: height,
                                            sequence: sequence, paintedAt: DispatchTime.now().uptimeNanoseconds,
                                            source: "software"), surface: surface)
    }

    /// The same page as a JPEG picture of `size` points, as Chromium answers a screenshot.
    private static func signInPicture(size: NSSize, scale: CGFloat = 2) -> Data? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        drawSignInPage(in: context, size: size, scale: scale)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    /// A page the agent wrote for the person, as Chromium pictures it: a heading and a few rows.
    private static func queuePicture(size: NSSize, scale: CGFloat = 2) -> Data? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        func text(_ string: String, _ point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular) {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: NSColor.black]).draw(at: point)
        }
        text("Posting queue", NSPoint(x: 32, y: 32), size: 24, weight: .semibold)
        for (index, row) in ["Fri 12:00  682 carousel", "Fri 21:00  087 reel", "Sat 12:00  087 carousel"].enumerated() {
            let y = 88 + CGFloat(index) * 40
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 32, y: y, width: min(size.width - 64, 420), height: 32).fill()
            text(row, NSPoint(x: 44, y: y + 7), size: 14)
        }
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    private static func drawSignInPage(in context: CGContext, size: NSSize, scale: CGFloat) {
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        let pageWidth = size.width
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pageWidth, height: size.height).fill()
        NSColor(red: 0.14, green: 0.18, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: pageWidth, height: 56).fill()
        func text(_ string: String, _ point: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: color]).draw(at: point)
        }
        text("Example Console", NSPoint(x: 16, y: 18), size: 15, color: .white, weight: .semibold)
        NSColor(red: 1, green: 0.6, blue: 0, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: pageWidth - 108, y: 12, width: 92, height: 32), xRadius: 6, yRadius: 6).fill()
        text("Sign in", NSPoint(x: pageWidth - 88, y: 19), size: 14, color: .black, weight: .semibold)
        text("Sign in to the console", NSPoint(x: 32, y: 88), size: 24, color: .black, weight: .semibold)
        NSColor.gray.setStroke()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 136, width: min(pageWidth - 64, 360), height: 36), xRadius: 6, yRadius: 6).stroke()
        text("Account ID or alias", NSPoint(x: 44, y: 145), size: 14, color: .gray)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 188, width: 120, height: 36), xRadius: 6, yRadius: 6).fill()
        text("Next", NSPoint(x: 76, y: 197), size: 14, color: .white, weight: .semibold)
        context.flush()
    }

    private func browserTabs(_ appearance: WindowlessRender.Appearance) throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let client = fixture.client
        let task = fixture.task
        let workspace = model.taskWorkspaces.state(for: task.id)
        let browserTitle = L10n.string("Browser")
        let blue = BrowserPanelTabsTests.icon(.systemBlue)
        let green = BrowserPanelTabsTests.icon(.systemGreen)

        model.splits.activate(.session(task.id))
        let host = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
        orderIn(host)
        defer { host.close() }

        // The launcher, then its Browser: a new browser tab, its address field ready.
        XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.launcherID)
        XCTAssertTrue(press(browserTitle, in: host), "the launcher's Browser")
        let first = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertTrue(waitUntil(host) { client.tab(key: first, forSession: task.id) != nil }, "the pane opened it")
        let firstTab = try XCTUnwrap(client.tab(key: first, forSession: task.id))
        let standIn = try XCTUnwrap(fixture.host())
        XCTAssertEqual(standIn.opened.last?.url, "about:blank")
        try draw(host, "new-tab", appearance)
        describe("Launcher's Browser → new tab", strip(in: host), notes: [
            "\(workspace.panels.trailingTabs.count) panel tabs, shown tab = the new browser tab, engine tab about:blank"
        ])
        standIn.load(firstTab.id, "http://localhost:3000/", title: "Login — Dev")
        host.settle(passes: 10, interval: 0.03)

        // The launcher's Browser always opens another one (the Codex app's); so does ⌘T on the page.
        XCTAssertTrue(pageKey("t", .command, keyCode: 17, in: host), "⌘T on the page")
        let second = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(waitUntil(host) { client.tab(key: second, forSession: task.id) != nil })
        let secondTab = try XCTUnwrap(client.tab(key: second, forSession: task.id))
        standIn.load(secondTab.id, "https://docs.test/", title: "Docs", icon: blue)

        // The agent opens a tab behind (browser_tab_new): it joins the strip; the panel keeps its tab.
        let agentTab = try client.newTab(forSession: task.id, url: "https://status.test/", viewport: .offscreenDefault,
                                         select: false)
        standIn.load(agentTab.id, "https://status.test/", title: "Status", icon: green)
        host.settle(passes: 12, interval: 0.03)
        XCTAssertEqual(Navigation.browserKeys(in: workspace.panels), [first, second, agentTab.key])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(second))
        let threeTabs = strip(in: host)
        XCTAssertTrue(threeTabs.contains { $0.label == "Login — Dev" }, "\(threeTabs.map(\.label))")
        XCTAssertTrue(threeTabs.contains { $0.label == "Status" })
        try draw(host, "three-tabs", appearance)
        describe("Three browser tabs (one from ⌘T, one the agent opened behind)", threeTabs, notes: [
            "Panel tabs: \(Navigation.browserKeys(in: workspace.panels).map { TaskSidePanelTabs.browserTab($0, in: workspace.browserTabs).title })",
            "Shown tab Docs (blue favicon), agent tab Status (green favicon) behind, no tab strip inside the browser pane"
        ])

        // The memory saver discards the hidden 'Login — Dev' (BROWSER_HOST section 3, "Memory saver"): its tab stays in the
        // strip with its icon in a dashed ring, and pressing it loads its page again.
        client.isMemorySaverOn = true
        defer { client.isMemorySaverOn = false }
        standIn.eventHandler?(.discarded(tab: firstTab.id))
        host.settle(passes: 10, interval: 0.03)
        XCTAssertEqual(workspace.browserTabs.tab(first)?.isDiscarded, true)
        try draw(host, "discarded-tab", appearance)
        describe("'Login — Dev' discarded by the memory saver", strip(in: host), notes: [
            "Its globe smaller and fainter in a dashed ring; Docs and Status as before"
        ])

        // A background tab pressed in the strip shows; the engine fronts it for the agent's tools.
        XCTAssertTrue(press("Login — Dev", in: host, among: threeTabs))
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))
        XCTAssertTrue(standIn.sent.contains(.navigation(tab: firstTab.id, action: .reload)), "shown, it loads its page again")
        XCTAssertFalse(firstTab.isDiscarded)
        XCTAssertTrue(client.tab(forSession: task.id) === firstTab)
        try draw(host, "background-tab-pressed", appearance)
        describe("Background tab 'Login — Dev' pressed", strip(in: host), notes: [
            "Shown tab = Login — Dev, and the engine's front tab is the same (the agent tools' default tab)"
        ])

        // ⌃Tab and ⌃⇧Tab on the page go to the next and previous browser tab, ⌘9 to the last. (⌘1–⌘4
        // stay the window's: the task's panels, as before.)
        XCTAssertTrue(pageKey("\t", .control, keyCode: 48, in: host), "⌃Tab")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(second))
        XCTAssertTrue(pageKey("9", .command, keyCode: 25, in: host), "⌘9")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(agentTab.key))
        XCTAssertTrue(pageKey("\t", [.control, .shift], keyCode: 48, in: host), "⌃⇧Tab")
        XCTAssertTrue(pageKey("\t", [.control, .shift], keyCode: 48, in: host), "⌃⇧Tab")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))

        // The agent fronts its tab (browser_tab_select): the panel, on a browser tab, shows it.
        agentTab.select()
        host.settle(passes: 10, interval: 0.03)
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(agentTab.key))
        try draw(host, "agent-fronted", appearance)

        // ⌘W on the page closes its tab and its page; the panel goes to the tab used before.
        XCTAssertTrue(pageKey("w", .command, keyCode: 13, in: host), "⌘W on the page")
        XCTAssertEqual(standIn.closed, [agentTab.id])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))
        XCTAssertEqual(Navigation.browserKeys(in: workspace.panels), [first, second])

        // ⌘⇧T opens it again as a new tab, shown.
        XCTAssertTrue(pageKey("t", [.command, .shift], keyCode: 17, in: host), "⌘⇧T")
        let reopened = try XCTUnwrap(client.tab(forSession: task.id))
        XCTAssertEqual(standIn.opened.last?.url, "https://status.test/")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(reopened.key))

        // Review beside them; closing the browser tabs one by one leaves Review shown, not a hidden panel.
        workspace.setPanels(Navigation.showing("diff", in: workspace.panels))
        host.settle(passes: 10, interval: 0.03)
        for key in Navigation.browserKeys(in: workspace.panels) {
            workspace.setPanels(Navigation.showing(Navigation.browserTabID(key), in: workspace.panels))
            host.settle(passes: 10, interval: 0.03)
            let shownStrip = strip(in: host)
            XCTAssertTrue(press(L10n.string("Close tab"), in: host, among: shownStrip), "the shown tab's close")
        }
        XCTAssertEqual(workspace.panels.trailingTabs, ["diff"])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, "diff", "the panel stays with Review")
        XCTAssertTrue(client.tabs(forSession: task.id).isEmpty, "each tab's page closed with it")
        try draw(host, "browser-tabs-closed", appearance)
        describe("All browser tabs closed (Review remains)", strip(in: host), notes: [
            "The panel stays and shows Review, 0 engine tabs, \(standIn.closed.count) engine tabs closed"
        ])

        // A task a build before saved with one Browser tab of three: three tabs, the front one shown; it
        // opens with the others, under their keys.
        model.splits.activate(.session(fixture.legacy.id))
        host.settle(passes: 20, interval: 0.03)
        let legacy = model.taskWorkspaces.state(for: fixture.legacy.id)
        let legacyKeys = Navigation.browserKeys(in: legacy.panels)
        XCTAssertEqual(legacyKeys.count, 3)
        XCTAssertEqual(legacy.panels.trailingSurfaceID, Navigation.browserTabID(legacyKeys[1]))
        XCTAssertTrue(waitUntil(host) { client.tabs(forSession: fixture.legacy.id).count == 3 })
        XCTAssertEqual(client.tabs(forSession: fixture.legacy.id).map(\.key), legacyKeys)
        XCTAssertEqual(client.tab(forSession: fixture.legacy.id)?.key, legacyKeys[1])
        let legacyStrip = strip(in: host)
        try draw(host, "migrated", appearance)
        describe("One 'Browser' tab from an earlier build (three browser tabs)", legacyStrip, notes: [
            "Three panel tabs, the front tab (localhost:3000) shown, all three open together under the same keys"
        ])
    }

    /// Pages' long titles share the strip as Chrome's and the Claude app's tabs do: while the panel has room every
    /// tab shows its title, evenly shortened, and only a narrow panel takes the tabs not shown down to their icons,
    /// all within the panel. Drawn at the panel's widest, a third of the way and its narrowest (`long-titles-*`);
    /// until 2026-10-27 the tabs not shown were icons at every width.
    func testLongTitlesShareTheStrip() throws {
        let fixture = try makeFixture()
        let model = fixture.model, task = fixture.task, client = fixture.client
        let workspace = model.taskWorkspaces.state(for: task.id)
        model.splits.activate(.session(task.id))
        let host = WindowlessRender.Host(window(fixture, .light), size: Self.size, appearance: .light)
        orderIn(host)
        defer { host.close() }

        XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
        XCTAssertTrue(press(L10n.string("Browser"), in: host), "the launcher's Browser")
        let first = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertTrue(waitUntil(host) { client.tab(key: first, forSession: task.id) != nil })
        let standIn = try XCTUnwrap(fixture.host())
        let titles = ["GitHub - anthropics/claude-code: Claude Code is an agentic coding tool",
                      "Pull requests · acme/acme-platform-web", "Browser panel responsive layout check notes — Notion",
                      "Yardlet dashboard · local development server"]
        var tabs = [try XCTUnwrap(client.tab(key: first, forSession: task.id))]
        for _ in titles.dropFirst() {
            tabs.append(try client.newTab(forSession: task.id, url: "about:blank", viewport: .offscreenDefault, select: false))
        }
        for (index, tab) in tabs.enumerated() {
            standIn.load(tab.id, "https://example\(index).test/", title: titles[index], icon: BrowserPanelTabsTests.icon(.systemBlue))
        }
        host.settle(passes: 12, interval: 0.03)

        var widths: [String: [CGFloat]] = [:]
        for (name, ratio) in [("wide", 1.0), ("third", 0.33), ("narrow", 0.0)] {
            workspace.layout.panelWidthRatio = ratio
            host.settle(passes: 12, interval: 0.03)
            try draw(host, "long-titles-\(name)", .light)
            let shown = strip(in: host).filter { titles.contains($0.label) }
            widths[name] = shown.map(\.frame.width)
            describe("Four long-titled tabs, panel \(name)", shown, notes: [
                "Other tab widths \(shown.map { Int($0.frame.width) }), all inside the panel \(shown.allSatisfy { $0.frame.maxX <= Self.size.width })"
            ])
            XCTAssertTrue(shown.allSatisfy { $0.frame.maxX <= Self.size.width }, "\(name): \(shown.map(\.frame))")
        }
        // The three tabs not shown, with room: their titles, at one width.
        let wide = widths["wide"] ?? []
        XCTAssertEqual(wide.count, 3)
        XCTAssertTrue(wide.allSatisfy { $0 >= PanelTabMetrics.titledWidth }, "wide: \(wide)")
        XCTAssertLessThanOrEqual((wide.max() ?? 0) - (wide.min() ?? 0), 1, "wide: \(wide)")
        workspace.layout.panelWidthRatio = nil
        try (["# Browser tabs with long titles", ""] + report).joined(separator: "\n")
            .write(to: try WindowlessRender.directory(Self.folder).appending(path: "long-titles.md"), atomically: true, encoding: .utf8)
    }

    /// A tab pressed in the title bar's height drags along its strip and the window stays: the shown browser tab and
    /// the window's shown tab, as the tabs not shown, which are buttons. The strip's room between its tabs still moves
    /// the window. The window has the app's title bar and is not the active app's, as a test's never is; there a press
    /// on a shown tab's own content moved the window every time (`TabDragHandle`). The window's moves are counted, not
    /// made.
    func testATabDragsFromTheTitleBarWithoutMovingTheWindow() throws {
        let fixture = try makeFixture()
        let model = fixture.model, task = fixture.task, client = fixture.client
        let workspace = model.taskWorkspaces.state(for: task.id)
        model.splits.activate(.session(task.id))
        model.splits.openInNewTab(.session(fixture.legacy.id))
        model.splits.selectTab(.session(task.id))
        let host = WindowlessRender.Host(window(fixture, .light).ignoresSafeArea(.container, edges: .top),
                                         size: Self.size, appearance: .light, titled: true)
        orderIn(host)
        defer { host.close() }
        XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
        XCTAssertTrue(press(L10n.string("Browser"), in: host))
        let first = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertTrue(waitUntil(host) { client.tab(key: first, forSession: task.id) != nil })
        let standIn = try XCTUnwrap(fixture.host())
        let docs = try XCTUnwrap(client.tab(key: first, forSession: task.id))
        let status = try client.newTab(forSession: task.id, url: "about:blank", viewport: .offscreenDefault, select: false)
        standIn.load(docs.id, "https://docs.test/", title: "Docs")
        standIn.load(status.id, "https://status.test/", title: "Status")
        host.settle(passes: 12, interval: 0.03)

        var moves = 0
        let performDrag = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.performDrag(with:))))
        let original = method_getImplementation(performDrag)
        let counted: @convention(block) (NSWindow, NSEvent) -> Void = { _, _ in moves += 1 }
        method_setImplementation(performDrag, imp_implementationWithBlock(counted))
        defer { method_setImplementation(performDrag, original) }

        /// A press at `point` (from the window's top-left) moved right by `distance` and let go. The moves wait in the
        /// app's queue, as the window server's do, for whatever tracks the press.
        func drag(from point: CGPoint, by distance: CGFloat) throws {
            func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: host.window.frame.height - point.y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            for step in 1...8 {
                NSApp.postEvent(try event(.leftMouseDragged, x: point.x + distance * CGFloat(step) / 8), atStart: false)
            }
            NSApp.postEvent(try event(.leftMouseUp, x: point.x + distance), atStart: false)
            host.window.sendEvent(try event(.leftMouseDown, x: point.x))
            while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(),
                                             inMode: .default, dequeue: true) {
                host.window.sendEvent(next)
                host.settle(passes: 1, interval: 0.01)
            }
            host.settle(passes: 8, interval: 0.03)
        }
        let titleBar = controls(in: host).filter { $0.frame.maxY <= ParityTheme.titleBarHeight }
        let close = try XCTUnwrap(titleBar.first { $0.label == L10n.string("Close tab") }, "the shown browser tab's close")
        let statusTab = try XCTUnwrap(titleBar.first { $0.label == "Status" })
        let otherWindowTab = try XCTUnwrap(titleBar.first { $0.label == fixture.legacy.title })
        let y: CGFloat = 16
        XCTAssertLessThan(y, host.window.frame.height - host.window.contentLayoutRect.height, "in the title bar's height")

        try drag(from: CGPoint(x: statusTab.frame.minX - PanelTabMetrics.spacing / 2, y: y), by: 40)
        XCTAssertEqual(moves, 1, "the room between two tabs moves the window")

        // The shown browser tab, by the room between its title and its close button, past the middle of the next.
        let shownStart = CGPoint(x: close.frame.midX - 21, y: y)
        try drag(from: shownStart, by: statusTab.frame.midX + 10 - shownStart.x)
        XCTAssertEqual(moves, 1, "the shown browser tab moved the window")
        XCTAssertEqual(Navigation.browserKeys(in: workspace.panels), [status.key, docs.key], "the shown browser tab moved")

        // The window's shown tab, by its mark (the window's two tabs are as wide), past the middle of the other.
        let shownWindowTab = otherWindowTab.frame.offsetBy(dx: -otherWindowTab.frame.width - WindowTabMetrics.spacing, dy: 0)
        let markStart = CGPoint(x: shownWindowTab.minX + 17, y: y)
        try drag(from: markStart, by: otherWindowTab.frame.midX + 10 - markStart.x)
        XCTAssertEqual(moves, 1, "the window's shown tab moved the window")
        XCTAssertEqual(model.splits.tabs, [.session(fixture.legacy.id), .session(task.id)], "the window's shown tab moved")
    }

    /// A Claude adapter that starts sessions and sends nothing.
    private actor Recorder: HarnessAdapter {
        nonisolated let kind = HarnessKind.claudeCode
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
            -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                 workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle)
            async throws {}
        /// Open until the task closes, as a live harness's are: a finished stream reads as a lost connection.
        private var streams: [AsyncStream<HarnessEventEnvelope>.Continuation] = []
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
            streams.append(continuation)
            return stream
        }
        func close(_ session: HarnessSessionHandle) async {
            streams.forEach { $0.finish() }
            streams.removeAll()
        }
    }
}
