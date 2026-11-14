import Foundation

/// Chrome DevTools Protocol as the browser tools use it. `BrowserDevToolsClient` provides it for
/// any host that speaks CDP (CEF, WebView2); tests provide a scripted one.
@MainActor
protocol BrowserAgentCDP: AnyObject {
    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue
    /// A command for a frame from another site, on its own session (`frameSessions`); nil is the tab's own.
    func send(_ method: String, _ params: [String: JSONValue], session: String?, timeout: Duration) async throws -> JSONValue
    /// Every CDP event of the tab's own session received so far, oldest first.
    var eventLog: [(method: String, params: JSONValue)] { get }
    /// The page's frames from other sites, each on a session of its own, once `attachFrames()` asked for them.
    var frameSessions: [BrowserFrameSession] { get }
    func attachFrames() async throws
}

extension BrowserAgentCDP {
    /// A connection without frame sessions (tests) answers only for the tab's own.
    func send(_ method: String, _ params: [String: JSONValue], session: String?, timeout: Duration) async throws -> JSONValue {
        guard session == nil else { throw BrowserDevToolsError.closed }
        return try await send(method, params, timeout: timeout)
    }
    var frameSessions: [BrowserFrameSession] { [] }
    func attachFrames() async throws {}
}

extension BrowserDevToolsClient: BrowserAgentCDP {
    var eventLog: [(method: String, params: JSONValue)] { events }

    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        try await send(method, params, session: nil, timeout: timeout)
    }
}

/// One task's page as the tools see it: its CDP connection, the references of its latest
/// snapshot, and what the host reported that CDP does not carry (a JavaScript dialog or a file
/// chooser waiting for an answer, a navigation the address policy blocked).
@MainActor
final class BrowserAgentPage {
    let cdp: any BrowserAgentCDP
    let tabID: BrowserTabID
    /// Sends a host command for this tab (dialog answers).
    private let sendCommand: (BrowserHostCommand) -> Void
    /// The task's project folders, the only places a file upload may come from.
    var workspaceRoots: [URL] = []
    /// Whether the tab's page responds (`BrowserTab.unresponsive`); tests leave it responding.
    var unresponsive: () -> BrowserTabUnresponsiveness? = { nil }
    /// After a call (its method) to the tab timed out, whether its renderer answered the check after it
    /// (`BrowserTab.rendererAnswered`); nil when nothing was checked, as in tests.
    var rendererAnswered: (String) async -> Bool? = { _ in nil }
    /// How the tab's renderer ended, until the page loads again (`BrowserTab.crash`).
    var crash: () -> BrowserTabCrash? = { nil }
    /// Why the host could not open the tab, which then has no page (`BrowserTab.openFailure`).
    var openFailure: () -> BrowserTabOpenFailure? = { nil }
    /// The size the host draws the tab at (`BrowserTab.viewport`); nil in tests.
    var viewport: () -> BrowserViewport? = { nil }
    /// Asks the engine for a fresh frame of the page (`BrowserTab.askForFrame`), and when the last one came
    /// (`BrowserTab.lastViewFrameAt`); tests have no frames.
    var askForFrame: () -> Void = {}
    var lastFrameAt: () -> ContinuousClock.Instant? = { nil }
    /// The agent's `browser_navigate` opens an address in the tab (`BrowserTab.noteAgentOpened`).
    var agentOpens: (String) -> Void = { _ in }
    /// The agent acts on the page, as opposed to reading it (`BrowserTab.noteAgentInput`), and its act failed
    /// (`BrowserTab.undoAgentInput`).
    var agentActs: () -> Void = {}
    var agentActFailed: () -> Void = {}
    /// The screen size the tab's page is shown at, and who chose it (`BrowserTab.emulation`).
    var emulation: () -> BrowserViewportEmulation? = { nil }
    /// Holds the page's layout at a size while the tab is drawn larger for a capture, and ends the hold
    /// (`BrowserTab.holdLayout`, `releaseLayout`); without them (tests) the page's own session does.
    var holdsLayout: ((Double, Double) async throws -> Void)?
    var releasesLayout: (() async -> Void)?
    /// Shows the page at a screen size, or its own again (`BrowserTab.emulate`).
    var emulate: (BrowserViewportEmulation?) async throws -> Void = { _ in
        throw BrowserAgentToolError("This browser cannot emulate a screen size.")
    }
    /// The side-panel tab this is (`BrowserTab.key`), for the panel to show it; nil in tests.
    var tabKey: UUID?
    /// Whether the tab closed.
    var isClosed: () -> Bool = { false }
    /// Waits while the memory saver's discarded page loads again after the tools woke it (`BrowserTab.untilRestored`).
    var untilRestored: () async -> Void = {}
    /// Hands the tab to the person (`BrowserTab.handOff`), reads the handoff, and ends it.
    var handOff: (String) -> (handoff: BrowserHandoff, isNew: Bool)? = { _ in nil }
    var handoff: () -> BrowserHandoff? = { nil }
    var endHandoff: () -> Void = {}
    /// Asks the person to keep a two-factor setup the page shows (`BrowserTab.askToSaveSetup`), reads the ask, and
    /// ends it.
    var askToSaveSetup: (OneTimeCodeSetup, String) -> (ask: BrowserVaultSetupAsk, isNew: Bool)? = { _, _ in nil }
    var setupAsk: () -> BrowserVaultSetupAsk? = { nil }
    var endSetupAsk: () -> Void = {}
    /// Emulates a color scheme, or follows the Mac again (`BrowserTab.emulateColorScheme`).
    var emulateColorScheme: (String?) async throws -> Void = { _ in
        throw BrowserAgentToolError("This browser cannot emulate a color scheme.")
    }
    /// What the vault filled into the tab's documents; the tab's own (`BrowserTab.vaultFills`), which the
    /// person's fills from the panel record in too.
    var vaultFills = BrowserVaultFills()
    /// A tab linked to this one by `window.opener` (this tab's page opened it, or it opened this one, or so on through
    /// other tabs) that shows a document the vault filled: its id. Page scripts here can reach that document.
    var linkedVaultFill: () -> BrowserTabID? = { nil }
    /// The agent is about to run its own script here: the documents the tabs linked to this one by `window.opener`
    /// show now are noted as scripted (`BrowserVaultFills.noteScript`), as this tab's own is.
    var noteScriptInLinkedTabs: () async -> Void = {}
    /// Whether a tab linked to this one shows a document a script of the agent's may reach, which reaches this tab's.
    var linkedTabShowsScript: () -> Bool = { false }

    /// Whether a script of the agent's may reach `loaderID`, the document the tab shows: a fill there asks the person
    /// first.
    func scriptMayReach(_ loaderID: String) -> Bool {
        vaultFills.showsScriptedDocument || vaultFills.scriptedDocuments.contains(loaderID) || linkedTabShowsScript()
    }
    /// The vault's passkey waiting in this tab's authenticator for the page's next request.
    var armedPasskey: BrowserAgentArmedPasskey? {
        didSet { onArmedPasskeyChange?(self) }
    }
    /// The tools keep the pages that hold a passkey, to take them all back when the vault is turned off.
    var onArmedPasskeyChange: ((BrowserAgentPage) -> Void)?

    /// `@e3` → its element (a backend DOM node, and the session of its frame), from the latest snapshot.
    private(set) var refs: [String: BrowserAgentSnapshot.Ref] = [:]
    /// The reference each element of the document got in a snapshot, which it keeps in the later ones; a new document
    /// starts over.
    private var refNames: [BrowserAgentSnapshot.Ref: String] = [:]
    /// The number the tab's next new reference gets: a number never names two elements of the tab.
    private(set) var nextRefNumber = 1
    /// The latest snapshot's references ended with a navigation of the page (`clearRefs`).
    private(set) var refsEndedByNavigation = false
    /// Where each frame from another site sits, from the latest snapshot: its iframe, in the session of the frame
    /// that holds it.
    private(set) var frameOwners: [String: BrowserAgentSnapshot.Ref] = [:]
    private(set) var snapshotCount = 0
    /// Where the event log stood at the latest snapshot. A main-frame navigation after it ends the
    /// references even when the old document is kept alive (the back/forward cache), where its
    /// nodes would still answer with their old positions.
    private(set) var snapshotEventMark = 0
    var domainsEnabled = false

    /// A JavaScript dialog the page is paused on.
    private(set) var dialog: BrowserJavaScriptDialog?
    /// A file chooser waiting for files.
    private(set) var fileDialog: BrowserFileDialog?
    /// A permission the page asks for and waits on: the person answers it in the panel's bar, and the agent can only
    /// close it (`closePermission`).
    private(set) var permissionPrompt: BrowserPermissionPrompt?
    /// Addresses the host's policy refused that no tool result has named yet, oldest first. A
    /// refusal can arrive just after the tool that caused it answered, so the next result names it.
    private(set) var blockedNavigations: [String] = []
    private var dialogWatchers: [UUID: () -> Void] = [:]

    init(cdp: any BrowserAgentCDP, tabID: BrowserTabID = 0, send: @escaping (BrowserHostCommand) -> Void = { _ in }) {
        self.cdp = cdp
        self.tabID = tabID
        sendCommand = send
    }

    // MARK: References

    /// The references the document's elements already have, for the next snapshot to keep (`BrowserAgentSnapshot.render`):
    /// none once the main frame went to another document.
    func referenceNames() -> (named: [BrowserAgentSnapshot.Ref: String], next: Int) {
        if navigatedSinceSnapshot { refNames = [:] }
        return (refNames, nextRefNumber)
    }

    func replaceRefs(_ refs: [String: BrowserAgentSnapshot.Ref], frameOwners: [String: BrowserAgentSnapshot.Ref] = [:],
                     eventMark: Int, nextNumber: Int? = nil) {
        if navigatedSinceSnapshot { refNames = [:] }
        self.refs = refs
        for (name, element) in refs { refNames[element] = name }
        if let nextNumber { nextRefNumber = max(nextRefNumber, nextNumber) }
        self.frameOwners = frameOwners
        snapshotEventMark = eventMark
        snapshotCount += 1
        refsEndedByNavigation = false
    }

    /// The page navigated: its references end, and its next snapshot numbers its elements anew.
    func clearRefs() {
        refs = [:]
        refNames = [:]
        if snapshotCount > 0 { refsEndedByNavigation = true }
    }

    /// The address the main frame went to since `mark` in the event log, if it went to another document.
    func mainFrameNavigation(since mark: Int) -> String? {
        let log = cdp.eventLog
        guard log.count > mark else { return nil }
        return log[mark...].last { $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil }
            .map { $0.params["frame"]?["url"]?.stringValue ?? "" }
    }

    /// The address of a navigation of the main frame to another document that Chromium started and that has neither
    /// committed nor ended. The browser logs the start when it takes the navigation (`Page.frameStartedNavigating`),
    /// before the page's beforeunload handlers run and the request goes out, then a commit (`Page.frameNavigated`) or an
    /// end without one (`Page.frameStoppedLoading`); a navigation that replaces it logs a start of its own. The main
    /// frame keeps its id, which its latest commit in the log names, or the tree `seedFrames` started from. Read from the
    /// end of the log, back to that commit at most.
    func pendingNavigation() -> String? {
        let log = cdp.eventLog
        guard let main = log.last(where: { $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil })?
            .params["frame"]?["id"]?.stringValue ?? seededMainFrame else { return nil }
        for event in log.reversed() {
            switch event.method {
            case "Page.frameNavigated" where event.params["frame"]?["id"]?.stringValue == main,
                 "Page.frameStoppedLoading" where event.params["frameId"]?.stringValue == main:
                return nil
            case "Page.frameStartedNavigating" where event.params["frameId"]?.stringValue == main:
                // A move within the document commits in the renderer and waits for nothing.
                if ["sameDocument", "historySameDocument"].contains(event.params["navigationType"]?.stringValue) { continue }
                return event.params["url"]?.stringValue
            default:
                continue
            }
        }
        return nil
    }

    /// True when the main frame navigated since the latest snapshot.
    var navigatedSinceSnapshot: Bool {
        let log = cdp.eventLog
        guard log.count > snapshotEventMark else { return false }
        return log[snapshotEventMark...].contains {
            $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil
        }
    }

    // MARK: Files the page shows

    /// The `file:` address each frame shows, by frame id, as of `fileFrameMark` in the event log.
    private var fileFrames: [String: String] = [:]
    private var fileFrameMark = 0
    /// The main frame's id in the tree `seedFrames` started from.
    private var seededMainFrame: String?

    /// Starts from the page's frames as `Page.getFrameTree` gave them, then follows the frame navigations
    /// logged from `eventMark` on, where the Page domain was enabled.
    func seedFrames(_ tree: JSONValue, eventMark: Int) {
        seededMainFrame = tree["frameTree"]?["frame"]?["id"]?.stringValue
        fileFrames = [:]
        func visit(_ node: JSONValue) {
            if let frame = node["frame"], let id = frame["id"]?.stringValue, let url = frame["url"]?.stringValue,
               BrowserURLPolicy.scheme(of: url) == "file" {
                fileFrames[id] = url
            }
            node["childFrames"]?.arrayValue?.forEach(visit)
        }
        visit(tree["frameTree"] ?? .null)
        fileFrameMark = eventMark
    }

    /// The `file:` addresses the page's frames show now: a link, a script or an iframe can bring one in
    /// without `browser_navigate`.
    func shownFiles() -> Set<String> {
        let log = cdp.eventLog
        if fileFrameMark < log.count {
            for event in log[fileFrameMark...] {
                switch event.method {
                case "Page.frameNavigated":
                    guard let frame = event.params["frame"], let id = frame["id"]?.stringValue else { continue }
                    // A new document in the main frame takes its frames with it.
                    if frame["parentId"] == nil { fileFrames = [:] }
                    let url = frame["url"]?.stringValue ?? ""
                    fileFrames[id] = BrowserURLPolicy.scheme(of: url) == "file" ? url : nil
                case "Page.frameDetached":
                    if let id = event.params["frameId"]?.stringValue { fileFrames[id] = nil }
                default:
                    break
                }
            }
            fileFrameMark = log.count
        }
        return Set(fileFrames.values)
    }

    // MARK: Host events

    func receive(_ event: BrowserHostEvent) {
        switch event {
        case .javaScriptDialog(_, let dialog):
            self.dialog = dialog
            let watchers = dialogWatchers.values
            dialogWatchers = [:]
            watchers.forEach { $0() }
        case .javaScriptDialogReset:
            dialog = nil
        case .fileDialog(_, let dialog):
            fileDialog = dialog
        case .dialogClosed(_, let closed):
            // The person answered it in the panel, or it went with its page.
            if dialog?.id == closed { dialog = nil }
            if fileDialog?.id == closed { fileDialog = nil }
        case .permissionPrompt(_, let prompt):
            permissionPrompt = prompt
        case .permissionPromptDismissed(_, let prompt):
            if permissionPrompt?.id == prompt { permissionPrompt = nil }
        case .navigationBlocked(_, let url):
            blockedNavigations.append(url)
            if blockedNavigations.count > 50 { blockedNavigations.removeFirst(25) }
        case .filledValueBlocked:
            filledValueBlocks += 1
        case .openedTab(_, let newTab, let url):
            openedTabs.append((newTab, url))
        case .newWindow(_, let url, _, false), .blockedPopup(_, _, let url):
            blockedPopups.append(url)
            if blockedPopups.count > 25 { blockedPopups.removeFirst() }
        case .externalAppHandled(_, let url, let app, let outcome):
            externalApps.append((url, app, outcome))
            if externalApps.count > 25 { externalApps.removeFirst() }
        case .closed, .terminated, .pageCrashed:
            dialog = nil
            fileDialog = nil
            permissionPrompt = nil
        default:
            break
        }
    }

    /// New-window requests the page made since the last tool said so: the tab each opened (nil when
    /// the task had no room and the page went there itself) and its address.
    private(set) var openedTabs: [(tab: BrowserTabID?, url: String)] = []

    func takeOpenedTabs() -> [(tab: BrowserTabID?, url: String)] {
        defer { openedTabs = [] }
        return openedTabs
    }

    /// Pop-ups the page opened without a click, which the browser blocked, since the last tool said so.
    private(set) var blockedPopups: [String] = []

    func takeBlockedPopups() -> [String] {
        defer { blockedPopups = [] }
        return blockedPopups
    }

    /// What came of the page's requests to open other apps' addresses since the last tool said so.
    private(set) var externalApps: [(url: String, app: String?, outcome: BrowserExternalAppOutcome)] = []

    func takeExternalApps() -> [(url: String, app: String?, outcome: BrowserExternalAppOutcome)] {
        defer { externalApps = [] }
        return externalApps
    }

    /// The refusals not yet named, which are then counted as named.
    func takeBlockedNavigations() -> [String] {
        defer { blockedNavigations = [] }
        return blockedNavigations
    }

    /// Navigations the host refused since the last tool said so because their address carried a password the vault
    /// filled into the page (`guardFilledValues`).
    private(set) var filledValueBlocks = 0

    func takeFilledValueBlocks() -> Int {
        defer { filledValueBlocks = 0 }
        return filledValueBlocks
    }

    /// Has the host refuse the page's navigations to an address that carries one of these spellings of a password
    /// the vault is about to fill, until the page's main frame starts another document.
    func guardFilledValues(_ values: [String]) {
        guard !values.isEmpty else { return }
        sendCommand(.guardFilledValues(tab: tabID, values: values))
    }

    /// Calls `watcher` once, when a JavaScript dialog opens.
    func watchForDialog(_ watcher: @escaping () -> Void) -> UUID {
        let token = UUID()
        dialogWatchers[token] = watcher
        return token
    }

    func stopWatchingForDialog(_ token: UUID) {
        dialogWatchers[token] = nil
    }

    func answerDialog(accept: Bool, text: String?) -> BrowserJavaScriptDialog? {
        guard let dialog else { return nil }
        self.dialog = nil
        sendCommand(.javaScriptDialogResult(tab: tabID, dialog: dialog.id, accepted: accept, text: text))
        return dialog
    }

    /// Draws the tab at another size (the full-page screenshot, for the moment it captures).
    func holdLayout(width: Double, height: Double) async throws {
        if let holdsLayout { return try await holdsLayout(width, height) }
        _ = try await cdp.send("Emulation.setDeviceMetricsOverride", [
            "width": .integer(Int64(width)), "height": .integer(Int64(height)), "deviceScaleFactor": .integer(0),
            "mobile": .bool(false)
        ], timeout: .seconds(15))
    }

    func releaseLayout() async {
        if let releasesLayout { return await releasesLayout() }
        _ = try? await cdp.send("Emulation.clearDeviceMetricsOverride", [:], timeout: .seconds(15))
    }

    func resize(to viewport: BrowserViewport) {
        sendCommand(.resize(tab: tabID, viewport: viewport))
    }

    /// Closes the page's permission request as the bar's Close does (dismiss): the page's request ends refused, and nothing
    /// is allowed. Chromium counts it as the person's Close (three in a row refuse the site's requests for a while). The
    /// agent never allows one, nor blocks one, which Chromium would keep for the site in a profile the tasks share.
    func closePermission() -> BrowserPermissionPrompt? {
        guard let permissionPrompt else { return nil }
        self.permissionPrompt = nil
        sendCommand(.permissionResult(tab: tabID, prompt: permissionPrompt.id, result: .dismiss))
        return permissionPrompt
    }

    func answerFileDialog(paths: [String]?) -> BrowserFileDialog? {
        guard let fileDialog else { return nil }
        self.fileDialog = nil
        sendCommand(.fileDialogResult(tab: tabID, dialog: fileDialog.id, paths: paths))
        return fileDialog
    }
}
