import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The pane of one of a task's side-panel browser tabs. It shows that tab of the shared browser host
/// (see `BrowserHostClient` for when the tab and the host live and end), opening it when the host has
/// none for it yet, and routes the tab's dialogs, downloads and find results to native UI. The pane
/// stays while the panel goes from one browser tab to another, and shows the next (`followPanel(_:)`).
@MainActor
@Observable
final class BrowserHostPaneController {
    let session: UUID
    /// The task's workspace, whose side panel holds the tab and which opens it in the host.
    @ObservationIgnored let workspace: TaskWorkspaceState
    /// The side-panel tab this pane shows.
    private(set) var key: UUID
    var addressInput = ""
    var isEditingAddress = false
    /// What the pane last put in the address field; while the field still holds it, the person has
    /// not typed there.
    @ObservationIgnored private var placedAddress = ""
    /// The address field's suggestions while the person types (`BrowserAddressAutocomplete`).
    @ObservationIgnored private(set) lazy var autocomplete = BrowserAddressAutocomplete(
        history: { MacBrowserHost.shared.addressHistory }, service: MacBrowserHost.shared.searchSuggest)
    /// The text the pane itself last put in the address field for a suggestion, which is no typing.
    @ObservationIgnored private var placedFieldText: String?
    /// The address field's selection before its last edit, which tells a deletion from typing.
    @ObservationIgnored private var selectionBeforeEdit: NSRange?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// What the error card and "Unavailable" say: the shown tab's page failed to load (it shows the
    /// failed address), its renderer crashed, or the tab could not be created.
    private(set) var errorMessage: String?
    /// The address `errorMessage` failed at; a page committing at another address clears it.
    @ObservationIgnored private var errorAddress: String?
    /// A load error whose page has not committed yet: it becomes the card when the failed address
    /// commits, and a notice when loading ends with the earlier page still shown.
    @ObservationIgnored private var pendingError: (address: String, message: String)?
    private(set) var notice: String?
    /// The tab's page does not respond (`BrowserTab.unresponsive`): Chrome's "Page Unresponsive" with
    /// Wait and Reload.
    private(set) var isUnresponsive = false
    /// The tab's renderer ended (`BrowserTab.crash`): the Codex app's "This page crashed" with Chrome's
    /// error code, until the page loads again.
    private(set) var crash: BrowserTabCrash?
    private(set) var isAgentDriving = false
    /// The screen size the shown tab's page is emulated at, and who chose it (`BrowserTab.emulation`), for the
    /// Viewport menu.
    private(set) var emulation: BrowserViewportEmulation?
    /// The agent handed the shown tab to the person and waits for their answer (`BrowserTab.handoff`): a bar over the
    /// page with its reason, Done and Decline.
    private(set) var handoff: BrowserHandoff?
    /// What the shown tab's page asks permission for (`BrowserTab.permissionPrompt`): Chrome's permission
    /// bubble, as a bar over the page.
    private(set) var permissionPrompt: BrowserPermissionPrompt?
    /// Another app's address the page asked to open (`BrowserTab.externalAppQuestion`): Chrome's "Open ‹app›?",
    /// as a bar over the page, with its "Always allow" box.
    private(set) var externalAppQuestion: BrowserExternalAppQuestion?
    var alwaysAllowExternalApp = false
    /// The shown tab's JavaScript dialog (`BrowserTab.javaScriptDialog`), drawn over the page as Chrome draws a tab's
    /// dialog over its tab: only this tab waits on it, the rest of the window stays the person's, and it stays with the
    /// tab while another is shown.
    private(set) var javaScriptDialog: BrowserJavaScriptDialog?
    /// What a prompt's field holds.
    var dialogText = ""
    /// The dialog takes the keyboard: the page had it when the dialog came, as a tab's dialog takes its page's focus.
    private(set) var dialogTakesKeyboard = false
    /// The shown tab's file chooser (`BrowserTab.fileDialog`). One the person's input opened opens over the panel;
    /// one the agent's input opened waits in a bar, for the agent (`browser_file_upload`) or for the person to open,
    /// so it takes no keyboard from what the person is doing.
    private(set) var fileDialog: BrowserFileDialog?
    private(set) var fileDialogByAgent = false
    /// Shows a file chooser over the panel (the system's open and save panels; QA fixtures put their own).
    @ObservationIgnored var fileChooser: any BrowserFileChooserPresenting = BrowserFileChooserPanel()
    /// Pop-ups the page opened without a click, which the browser blocked (`BrowserTab.blockedPopups`): Chrome's
    /// "Pop-ups blocked" in the address field, from which the person opens one.
    private(set) var blockedPopups: [String] = []
    /// The vault (docs/BROWSER_VAULT_DESIGN.md §8): what the person signed in with, offered for saving;
    /// the vault filling this tab for an agent (the header says so); a passkey being made; a new item's draft.
    var vaultOffer: BrowserVaultSaveOffer?
    var isVaultFilling = false
    var isMakingPasskey = false
    var vaultDraft: BrowserVaultDraft?
    /// "Import Sign-ins from Another Browser…" from the page's menu, while its sheet is open.
    var loginImport: BrowserLoginImportRequest?
    /// Two-factor codes (§14): a code field to fill the current code into; a setup QR code to save.
    var vaultCodeOffer: BrowserVaultCodeOffer?
    var vaultSetupOffer: BrowserVaultSetupOffer?
    /// Strong passwords (§15): an empty new-password field to suggest one for; the page whose password field
    /// has the focus (the page menu offers one there); the pages the bar showed on, where it does not show
    /// again; the item a password made in a tab was presaved in, which submitting the form completes.
    var vaultPasswordOffer: BrowserVaultPasswordOffer?
    @ObservationIgnored var focusedPasswordPage: String?
    @ObservationIgnored var offeredPasswordPages: Set<String> = []
    @ObservationIgnored var madePassword: BrowserVaultMadePassword?
    @ObservationIgnored var isScanningForCodes = false
    /// Setup codes the person said no to, not offered again while the tab is shown.
    @ObservationIgnored var dismissedSetups: Set<Data> = []
    @ObservationIgnored var vaultWatch: (tab: BrowserTabID, token: UUID)?
    @ObservationIgnored var vaultFillObserver: (any NSObjectProtocol)?
    @ObservationIgnored var vaultIndicatorTask: Task<Void, Never>?
    @ObservationIgnored var passkeyTask: Task<Void, Never>?
    /// The panel picks an element of the page for the task's next message (`BrowserElementPicker`):
    /// the toolbar's button turns it on and off, Escape and a pick end it.
    private(set) var isPickingElement = false
    @ObservationIgnored private var picker: BrowserElementPicker?
    /// Where a picked element goes: the task's composer. Nil leaves the panel without the button.
    @ObservationIgnored var onPickElement: ((BrowserComment) -> Void)?
    var isFindVisible = false
    var findText = ""
    private(set) var findResult: BrowserFindResult?
    private(set) var downloads: [BrowserDownload] = []
    /// The host's tab for `key`, once it is open.
    @ObservationIgnored private(set) var tab: BrowserTab?
    @ObservationIgnored private var tabsObserver: UUID?
    /// While attached, the pane follows the browser tab the panel shows (`followPanel(_:)`); each attach
    /// starts its own follow, and detaching ends it.
    @ObservationIgnored private var panelFollow: UUID?
    /// The side panel's own actions for the page's keys: a new tab (⌘T), closing this one (⌘W), and
    /// showing another of the task's browser tabs (⌃Tab, ⌘1…⌘9).
    @ObservationIgnored var onNewTab: (() -> Void)?
    @ObservationIgnored var onCloseTab: ((UUID) -> Void)?
    @ObservationIgnored var onShowTab: ((UUID) -> Void)?
    /// The page's accessibility for VoiceOver; exists while a tab is shown.
    @ObservationIgnored private(set) var accessibility: BrowserAccessibilityBridge?
    @ObservationIgnored private(set) weak var view: BrowserHostView?
    /// The panel told the lifetime manager it is off screen (`BrowserHostClient.setPanelOccluded`).
    @ObservationIgnored private var isPanelOccluded = false
    @ObservationIgnored private var agentIndicatorTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Called for every event of the attached tab (QA fixtures record them).
    @ObservationIgnored var eventObserver: ((BrowserHostEvent) -> Void)?
    /// Called for every page frame placed on screen, on the thread that placed it, with its
    /// paint-to-display latency in milliseconds.
    @ObservationIgnored var frameObserver: (@Sendable (BrowserFrame, Double) -> Void)? {
        didSet { view?.frameDisplay.setObserver(frameObserver) }
    }
#if DEBUG
    /// QA fixtures answer file dialogs themselves instead of showing the open panel.
    @ObservationIgnored var fileDialogOverride = false
#endif

    /// The most recently attached controller, for DEBUG QA fixtures.
    @ObservationIgnored static weak var current: BrowserHostPaneController?

    let client: BrowserHostClient

    init(session: UUID, key: UUID, workspace: TaskWorkspaceState, client: BrowserHostClient) {
        self.session = session
        self.key = key
        self.workspace = workspace
        self.client = client
        placeAddress(workspace.browserTabs.tab(key)?.address ?? "")
    }

    var hasTab: Bool { tab != nil }

    /// The page's icon, as its side-panel tab shows it.
    var favicon: Data? { workspace.browserTabs.tab(key)?.favicon }

    // MARK: Lifecycle

    func attach(_ view: BrowserHostView) {
        self.view = view
        Self.current = self
        view.surfaceProvider = { MacBrowserHost.shared.surface(for: $0) }
        view.frameDisplay.setObserver(frameObserver)
        view.onOcclusionChange = { [weak self] occluded in self?.panelOcclusionChanged(occluded) }
        view.onShortcut = { [weak self] shortcut in self?.perform(shortcut) }
        view.onEscape = { [weak self] in
            guard let self, self.isPickingElement else { return false }
            self.stopPickingElement()
            return true
        }
        // Whether the person is using the shown tab: their keyboard is in its page (`BrowserHostClient.personUse`).
        view.onKeyboardChange = { [weak self] hasKeyboard in
            guard let self, let tab = self.tab else { return }
            self.client.setPanelKeyboard(hasKeyboard, on: tab)
        }
        // A chooser the person asked for opens once the panel is in a window.
        view.onWindowChange = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.showFileDialog(of: tab)
        }
        // The pane follows its tab whoever opens, fronts or closes tabs.
        if tabsObserver == nil {
            tabsObserver = client.addTabsObserver(forSession: session) { [weak self] in self?.tabsChanged() }
        }
        open()
        let follow = UUID()
        panelFollow = follow
        followPanel(follow)
    }

    /// Shows the browser tab the side panel shows, now and whenever the panel changes, until the pane
    /// detaches. The pane follows the workspace itself: SwiftUI runs an `onChange(of:)` action once a
    /// frame, so the panel changing tabs twice before the window drew again (the agent fronting and
    /// closing a tab, ⌘W twice, a busy main thread, a window not drawn at all) left the pane on a tab the
    /// panel no longer showed.
    private func followPanel(_ follow: UUID) {
        guard panelFollow == follow else { return }
        let shown = withObservationTracking {
            TaskSurfaceNavigationProjection.browserKey(inTab: workspace.panels.trailingSurfaceID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPanel(follow) }
        }
        if let shown { show(shown) }
    }

    /// The panel went to another of the task's browser tabs.
    private func show(_ key: UUID) {
        guard key != self.key else { return }
        self.key = key
        if let tab { release(tab) }
        errorMessage = nil
        isEditingAddress = false
        autocomplete.close()
        placeAddress(workspace.browserTabs.tab(key)?.address ?? "")
        open()
    }

    /// Shows the host's tab for `key`, opening it when the host has none: a tab saved before Yardlet
    /// restarted or lost with the host opens at its page (with the task's other such tabs), a new tab at
    /// its address or blank, with the address field ready.
    private func open() {
        guard let view else { return }
        do {
            // Only a blank tab opened here waits for an address; a tab the agent or a page opened is
            // already on its way to its page.
            let existed = client.tab(key: key, forSession: session) != nil
            let opened = try workspace.openBrowserEngineTab(key, viewport: view.viewport)
            if !existed, let opened, opened.lastPageURL == nil, workspace.browserTabs.tab(key)?.address.isEmpty ?? true {
                placeAddress("")
                isEditingAddress = true
            }
        } catch is BrowserTabLimitError {
            errorMessage = L10n.string("Tab limit reached. Close a tab to open a new one.")
        } catch {
            errorMessage = L10n.format("Chromium could not start: %@", error.localizedDescription)
        }
        tabsChanged()
    }

    /// The task's tabs changed: the pane shows the host's tab for its key, and lets go of one closed.
    private func tabsChanged() {
        let current = client.tab(key: key, forSession: session)
        let unresponsive = current?.unresponsive != nil
        if unresponsive != isUnresponsive { isUnresponsive = unresponsive }
        if current?.crash != crash { crash = current?.crash }
        guard current !== tab else { return }
        if let tab { release(tab) }
        // The next tab's first frame replaces the last one shown; with none, the page area empties.
        if let current { adopt(current) } else { view?.clear() }
    }

    /// The panel left the screen. The tabs stay for the agent and for a quick return, until they are
    /// closed.
    func detach() {
        if let tabsObserver { client.removeTabsObserver(tabsObserver, forSession: session) }
        tabsObserver = nil
        panelFollow = nil
        if let tab { release(tab) }
        agentIndicatorTask?.cancel()
    }

    /// Stops showing a tab: its dialogs, accessibility, frames and events go back to nobody.
    private func release(_ tab: BrowserTab) {
        stopPickingElement()
        // The tab's dialog and file chooser stay with it, waiting for the next panel that shows it.
        javaScriptDialog = nil
        fileDialog = nil
        fileChooser.dismiss()
        client.setPanelKeyboard(false, on: tab)
        stopAccessibility(sendingDisable: true)
        // The keyboard focus stays with the view for the next tab; this page no longer has it.
        if view?.hasKeyboardFocus == true { tab.send(.focus(tab: tab.id, isFocused: false)) }
        if let view {
            MacBrowserHost.shared.stopShowingFrames(of: tab.id, in: view.frameDisplay)
            MacBrowserHost.shared.panelStopsShowing(tab.id, in: view)
        }
        client.detachPanel(from: tab, occluded: isPanelOccluded)
        tab.eventHandler = nil
        tab.onAgentActivity = nil
        tab.onEmulationChange = nil
        tab.onHandoffChange = nil
        emulation = nil
        handoff = nil
        view?.emulatedSize = nil
        releaseVault(tab)
        isPanelOccluded = false
        self.tab = nil
        view?.tabID = nil
        view?.sendCommand = nil
        view?.setPopup(nil)
        title = ""
        isLoading = false
        permissionPrompt = nil
        externalAppQuestion = nil
        blockedPopups = []
    }

    func retry() {
        clearError()
        if let tab, tab.openFailure != nil {
            // The host could not open the tab: it opens again in its place.
            reopen(tab)
        } else if let tab {
            tab.send(.navigation(tab: tab.id, action: .reload))
        } else {
            view?.clear()
            // The tabs the host lost come back together, this one in front.
            open()
        }
    }

    private func adopt(_ tab: BrowserTab) {
        guard let view else { return }
        self.tab = tab
        // What the header and toolbar show come from the tab, which kept them while another was shown.
        title = tab.title
        isLoading = tab.isLoading
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        permissionPrompt = tab.permissionPrompt
        externalAppQuestion = tab.externalAppQuestion
        alwaysAllowExternalApp = false
        blockedPopups = tab.blockedPopups
        clearError()
        // A tab the host could not open says why, though it failed before this panel showed it.
        if let failure = tab.openFailure { errorMessage = Self.message(for: failure) }
        findResult = nil
        isFindVisible = false
        tab.eventHandler = { [weak self] event in self?.handle(event) }
        tab.onAgentActivity = { [weak self] in self?.agentUsedBrowser() }
        tab.onEmulationChange = { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.showEmulation(of: tab)
        }
        showEmulation(of: tab)
        tab.onHandoffChange = { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.showHandoff(of: tab)
        }
        showHandoff(of: tab)
        adoptVault(tab, in: view)
        view.tabID = tab.id
        view.isPasswordFieldFocused = tab.isPasswordFieldFocused
        view.sendCommand = { [weak tab] command in tab?.send(command) }
        // A tab shown in a view that has the keyboard focus (another browser tab, one opened again or
        // replaced) gets it, as when the view becomes first responder; before, only that sent it.
        if view.hasKeyboardFocus { tab.send(.focus(tab: tab.id, isFocused: true)) }
        MacBrowserHost.shared.showFrames(of: tab.id, in: view.frameDisplay)
        startAccessibility(tab: tab, view: view)
        // Attaching shows the tab to its engine and asks for a fresh frame, so a tab adopted from an
        // earlier panel (or opened by the agent) paints again now.
        client.attachPanel(to: tab)
        isPanelOccluded = false
        if view.isOccluded { panelOcclusionChanged(true) }
        // Chromium's window over this tab (a passkey dialog) shows over this panel.
        MacBrowserHost.shared.panelShows(tab.id, in: view)
        view.resendViewport()
        client.setPanelKeyboard(view.hasKeyboardFocus && view.window?.isKeyWindow == true, on: tab)
        // A tab opened again shows the page it opens before the page reports its address.
        showAddress(tab.currentURL ?? workspace.browserTabs.tab(key)?.address ?? "")
        // What the page waits on shows now, also what it asked while another tab or task was shown (a "Leave site?"
        // the person's close brought this tab forward for, among them).
        showJavaScriptDialog(tab.javaScriptDialog)
        showFileDialog(of: tab)
    }

    // MARK: Screen sizes

    /// The view draws the tab at its emulated size, or at the view's own.
    private func showEmulation(of tab: BrowserTab) {
        emulation = tab.emulation
        view?.emulatedSize = tab.emulation.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The person's Viewport menu: a size the page is shown at until they or the agent change it, or the panel's own
    /// size again (Responsive, nil).
    func setViewport(_ preset: BrowserViewportEmulation.Preset?) {
        guard let tab else { return }
        Task { try? await tab.emulate(preset.map { BrowserViewportEmulation($0, owner: .person) }) }
    }

    // MARK: Handing the tab to the person

    private func showHandoff(of tab: BrowserTab) {
        handoff = tab.handoff?.answer == nil ? tab.handoff : nil
    }

    /// The person's Done or Decline in the handoff bar: the agent's wait reads it, and the notification goes.
    func answerHandoff(_ answer: BrowserHandoff.Answer) {
        guard let tab, let handoff = tab.handoff else { return }
        tab.answerHandoff(answer)
        MacAgentToolService.shared.broker.handoffs?.handoffEnded(notice: BrowserAgentTools.handoffNotice(handoff.id))
    }

    // MARK: A page that does not respond

    /// The header's one line for the tab's state, the first that holds: not responding (the renderer
    /// is there but busy), crashed (the renderer ended), unavailable (a move that failed), loading, ready.
    static func status(isUnresponsive: Bool, isCrashed: Bool = false, hasError: Bool, isLoading: Bool,
                       hasTab: Bool) -> String? {
        if isUnresponsive { return L10n.string("Not responding") }
        if isCrashed { return L10n.string("Crashed") }
        if hasError { return L10n.string("Unavailable") }
        if isLoading { return L10n.string("Loading") }
        return hasTab ? L10n.string("Ready") : nil
    }

    /// Waits for the page, as Chrome's Wait does.
    func waitForUnresponsivePage() {
        guard let tab else { return }
        client.waitForPage(tab)
    }

    /// Opens the page again in place of the stuck one (its renderer ended first when Chromium holds it).
    func reloadUnresponsivePage() {
        guard let tab else { return }
        reopen(tab)
    }

    /// Opens the tab again in its place, under the same side-panel tab, at `url` or its page: a stuck page,
    /// or a tab the host could not open.
    private func reopen(_ tab: BrowserTab, at url: String? = nil) {
        let address = url ?? tab.lastPageURL ?? workspace.browserTabs.tab(key)?.address ?? "about:blank"
        do {
            try client.replace(tab, url: address.isEmpty ? "about:blank" : address)
        } catch {
            errorMessage = L10n.format("Chromium could not start: %@", error.localizedDescription)
        }
    }

    // MARK: The task's other browser tabs (keys on the page)

    /// The task's browser tabs in the panel's order, which is the host's.
    private var browserKeys: [UUID] { TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels) }

    /// The next or previous of the task's browser tabs, wrapping around (⌃Tab, ⌃⇧Tab).
    func showAdjacentTab(_ offset: Int) {
        let keys = browserKeys
        guard keys.count > 1, let index = keys.firstIndex(of: key) else { return }
        onShowTab?(keys[(index + offset + keys.count) % keys.count])
    }

    /// ⌘1…⌘8 show that browser tab; ⌘9 the last, as browsers do.
    func showTab(atShortcut number: Int) {
        let keys = browserKeys
        guard !keys.isEmpty else { return }
        let index = number == 9 ? keys.count - 1 : number - 1
        if keys.indices.contains(index) { onShowTab?(keys[index]) }
    }

    func reopenClosedTab() {
        guard let view else { return }
        do {
            try workspace.reopenClosedBrowserTab(viewport: view.viewport)
        } catch is BrowserTabLimitError {
            showNotice(L10n.string("Tab limit reached. Close a tab to open a new one."))
        } catch {
            errorMessage = L10n.format("Chromium could not start: %@", error.localizedDescription)
        }
    }

    /// The panel left or came back on screen (window miniaturized, covered, on another space, app
    /// hidden). Off screen, the tab stops painting like a panel-less one.
    private func panelOcclusionChanged(_ occluded: Bool) {
        guard let tab, occluded != isPanelOccluded else { return }
        isPanelOccluded = occluded
        client.setPanelOccluded(occluded, on: tab)
        MacBrowserHost.shared.chromiumWindows.present()
        // A chooser the person asked for opens once the panel is on screen (a window that was not drawn yet).
        if !occluded { showFileDialog(of: tab) }
    }

    // MARK: Navigation

    func submitAddress() {
        // Return opens the selected suggestion, as in Chrome; the first row only when it can be first.
        let chosen = autocomplete.selected.flatMap { autocomplete.selection > 0 || $0.canBeDefault ? $0 : nil }
        autocomplete.close()
        isEditingAddress = false
        do {
            let url = try chosen?.destination ?? BrowserURLPolicy.addressFieldURL(addressInput)
            errorMessage = nil
            if let tab, tab.openFailure != nil {
                reopen(tab, at: url)
            } else if let tab {
                tab.notePersonInput()
                tab.noteTypedNavigation()
                tab.send(.navigate(tab: tab.id, url: url))
            } else {
                // The host could not open the tab before; it opens at the address.
                workspace.browserTabs.setAddress(url, for: key)
                open()
            }
            // As in Chrome (`SetInitialFocus` after a navigation the person starts), the page takes the
            // keyboard from the address field, so its autofocused field shows the caret and takes typing.
            if let view { view.window?.makeFirstResponder(view) }
        } catch {
            showNotice(Self.message(for: error))
        }
    }

    // MARK: Address suggestions (docs/BROWSER_HOST.md, "Address suggestions")

    /// The address field's text changed. What the person types updates the suggestions, and while they type at the
    /// end, not right after deleting and not while an input method composes, the first row's completion follows the
    /// caret, selected (Chrome's inline autocompletion). Deleting is Chrome's `just_deleted_text`: the text got
    /// shorter and the caret is not past where the selection before the edit began.
    func addressTextChanged(from old: String, to text: String) {
        if text == placedFieldText { return }
        placedFieldText = nil
        guard isEditingAddress, text != placedAddress else { return autocomplete.close() }
        let editor = addressEditor
        let length = (text as NSString).length
        let caret = editor.map { $0.string == text ? $0.selectedRange() : NSRange(location: length, length: 0) }
            ?? NSRange(location: length, length: 0)
        let deleted = (old as NSString).length > length && selectionBeforeEdit.map { caret.location <= $0.location } == true
        let atEnd = caret == NSRange(location: length, length: 0)
        autocomplete.update(typed: text, allowsInline: atEnd && !deleted && editor?.hasMarkedText() != true)
        if autocomplete.rows.first?.inlineCompletion.isEmpty == false { showSelectedSuggestion() }
        selectionBeforeEdit = editor?.selectedRange()
    }

    /// A text view's selection changed: the address field's, while it still holds the text the pane knows (not in the
    /// middle of an edit), is the selection the next edit starts from.
    func addressSelectionChanged(in textView: Any?) {
        guard let editor = addressEditor, (textView as AnyObject?) === editor, editor.string == addressInput else { return }
        selectionBeforeEdit = editor.selectedRange()
    }

    /// The address field gained or lost the keyboard; the suggestions close with it.
    func addressFocusChanged(_ focused: Bool) {
        isEditingAddress = focused
        selectionBeforeEdit = nil
        if !focused { autocomplete.close() }
    }

    /// ↑ ↓ Tab ⇧Tab while the suggestions are open: the next or previous row, wrapping around.
    func moveSuggestion(by offset: Int) -> Bool {
        guard autocomplete.isOpen, addressEditor?.hasMarkedText() != true else { return false }
        autocomplete.move(by: offset)
        showSelectedSuggestion()
        return true
    }

    /// Escape, as Chrome's `OnEscapeKeyPressed`: a row the person moved to goes back to the first, open
    /// suggestions close, then the field shows the page's address again all selected, and once it does the page
    /// takes the keyboard.
    func escapeAddress() {
        if autocomplete.isOpen, autocomplete.selection != 0 {
            autocomplete.select(0)
            showSelectedSuggestion()
        } else if autocomplete.isOpen {
            autocomplete.close()
        } else if addressInput != placedAddress {
            let shown = Self.shownAddress(tab?.currentURL ?? workspace.browserTabs.tab(key)?.address ?? "")
            placedAddress = shown
            setFieldText(shown, selecting: NSRange(location: 0, length: (shown as NSString).length))
        } else if let view, hasTab {
            view.window?.makeFirstResponder(view)
        }
    }

    /// Shift-Delete (⇧fn⌫) on a row from the history, or its remove button: Chrome deletes the page or search.
    @discardableResult
    func removeSuggestion(at index: Int? = nil) -> Bool {
        guard autocomplete.isOpen else { return false }
        if let index { autocomplete.select(index) }
        guard autocomplete.removeSelected() else { return false }
        if autocomplete.isOpen { showSelectedSuggestion() } else { setFieldText(autocomplete.typed, selecting: nil) }
        return true
    }

    /// A click on a row opens it.
    func openSuggestion(at index: Int) {
        autocomplete.select(index)
        submitAddress()
    }

    /// The field shows the selected row: what was typed and the first row's completion selected after the caret,
    /// or another row's text with the caret at its end (Chrome's temporary text).
    private func showSelectedSuggestion() {
        guard let row = autocomplete.selected else { return }
        if autocomplete.selection == 0 {
            let typed = autocomplete.typed
            setFieldText(typed + row.inlineCompletion, selecting: NSRange(
                location: (typed as NSString).length, length: (row.inlineCompletion as NSString).length))
        } else {
            setFieldText(row.fill, selecting: nil)
        }
    }

    /// Puts `text` in the address field through its field editor, changing only what differs, so the caret and
    /// selection land where `range` says (the end when nil).
    private func setFieldText(_ text: String, selecting range: NSRange?) {
        placedFieldText = text
        if let editor = addressEditor {
            let old = editor.string as NSString, new = text as NSString
            var start = 0
            while start < old.length, start < new.length, old.character(at: start) == new.character(at: start) { start += 1 }
            if start > 0, start < old.length, CFStringIsSurrogateLowCharacter(old.character(at: start)) { start -= 1 }
            let changed = NSRange(location: start, length: old.length - start)
            let replacement = new.substring(from: start)
            if changed.length > 0 || !replacement.isEmpty, editor.shouldChangeText(in: changed, replacementString: replacement) {
                editor.replaceCharacters(in: changed, with: replacement)
                editor.didChangeText()
            }
            editor.setSelectedRange(range ?? NSRange(location: new.length, length: 0))
        }
        addressInput = text
        selectionBeforeEdit = range ?? NSRange(location: (text as NSString).length, length: 0)
    }

    /// The address field's field editor while the field has the keyboard.
    private var addressEditor: NSTextView? {
        guard isEditingAddress, let editor = view?.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    func navigate(_ action: BrowserNavigationAction) {
        guard let tab else { return }
        if action == .reload, tab.openFailure != nil { return retry() }
        tab.notePersonInput()
        if action == .reload { errorMessage = nil }
        tab.send(.navigation(tab: tab.id, action: action))
    }

    func openExternally() {
        guard let url = BrowserTabMenuActions.externalURL(tab?.currentURL ?? workspace.browserTabs.tab(key)?.address) else { return }
        OutsideBrowser.open(url)
    }

    private func perform(_ shortcut: BrowserPanelShortcut) {
        if shortcut == .newTab, TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels).count
            >= BrowserHostClient.maxTabsPerSession {
            return showNotice(L10n.string("Tab limit reached. Close a tab to open a new one."))
        }
        switch shortcut {
        case .find: isFindVisible = true
        case .focusAddress: isEditingAddress = true
        case .reload: navigate(.reload)
        case .back: navigate(.back)
        case .forward: navigate(.forward)
        case .newTab: onNewTab?()
        case .closeTab: onCloseTab?(key)
        case .reopenClosedTab: reopenClosedTab()
        case .nextTab: showAdjacentTab(1)
        case .previousTab: showAdjacentTab(-1)
        case .selectTab(let number): showTab(atShortcut: number)
        }
    }

    // MARK: Picking an element

    /// The toolbar's button: picking starts (the page takes the keyboard, so Escape reaches the panel)
    /// or stops.
    func togglePickingElement() {
        if isPickingElement { return stopPickingElement() }
        guard let tab, onPickElement != nil else { return }
        let picker = BrowserElementPicker(devTools: tab.devTools)
        self.picker = picker
        isPickingElement = true
        picker.onPick = { [weak self, weak tab, weak picker] node in
            guard let self, let tab, let picker else { return }
            self.picked(node, on: tab, by: picker)
        }
        picker.onCancel = { [weak self] in self?.stopPickingElement() }
        if let view { view.window?.makeFirstResponder(view) }
        Task { @MainActor [weak self] in
            do {
                try await picker.start()
            } catch {
                guard let self, self.picker === picker else { return }
                self.picker = nil
                self.isPickingElement = false
                self.showNotice(L10n.string("This page cannot pick an element."))
            }
        }
    }

    func stopPickingElement() {
        guard let picker else { return }
        self.picker = nil
        isPickingElement = false
        Task { await picker.stop() }
    }

    /// One pick a time, as DevTools' "Select an element": the mode ends, then the element's context
    /// and capture go to the task's composer.
    private func picked(_ node: Int64, on tab: BrowserTab, by picker: BrowserElementPicker) {
        // A second click before the mode is off (a double click) picks nothing more.
        guard self.picker === picker else { return }
        self.picker = nil
        isPickingElement = false
        Task { @MainActor [weak self] in
            // The outline leaves the page before the capture.
            await picker.stop()
            do {
                let found = try await BrowserElementPicker.describe(
                    node, pageURL: tab.currentURL ?? "", on: tab.devTools,
                    scrub: MacAgentToolService.shared.broker.scrubVaultValues)
                var comment = found.comment
                if let png = found.png {
                    comment.image = await Task.detached(priority: .userInitiated) {
                        try? ComposerAttachmentIntake.storePastedImage(png, fileExtension: "png")
                    }.value
                }
                self?.onPickElement?(comment)
            } catch {
                self?.showNotice(L10n.string("The element could not be attached."))
            }
        }
    }

    // MARK: Find

    func find(backward: Bool = false) {
        guard let tab, !findText.isEmpty else { return }
        tab.send(.find(tab: tab.id, text: findText, forward: !backward, matchCase: false, findNext: findResult != nil))
    }

    func closeFind() {
        isFindVisible = false
        findResult = nil
        if let tab { tab.send(.stopFinding(tab: tab.id, clearSelection: true)) }
        if let view { view.window?.makeFirstResponder(view) }
    }

    func findTextChanged() {
        findResult = nil
        guard let tab else { return }
        if findText.isEmpty {
            tab.send(.stopFinding(tab: tab.id, clearSelection: true))
        } else {
            tab.send(.find(tab: tab.id, text: findText, forward: true, matchCase: false, findNext: false))
        }
    }

    // MARK: Downloads

    func cancelDownload(_ download: BrowserDownload) {
        tab?.send(.cancelDownload(tab: tab?.id ?? 0, download: download.id))
    }

    func dismissDownload(_ download: BrowserDownload) {
        downloads.removeAll { $0.id == download.id }
    }

    func revealDownload(_ download: BrowserDownload) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: download.path)])
    }

    // MARK: Events

    private func handle(_ event: BrowserHostEvent) {
        switch event {
        case .frame(_, let frame):
            view?.show(frame)
        case .popup(_, let rect):
            view?.setPopup(rect)
        case .cursor(_, let cursor):
            view?.setCursor(cursor)
        case .tooltip(_, let text):
            view?.setTooltip(text)
        case .contextMenu(_, let menu):
            view?.showContextMenu(menu)
        case .compositionBounds(_, let rects):
            view?.setCompositionBounds(rects)
        case .dragOperation(_, let operations):
            view?.setDragOperations(operations)
        case .passwordField(_, let isFocused):
            view?.isPasswordFieldFocused = isFocused
        case .address(_, let url):
            showAddress(url)
            vaultPageMoved(to: url)
            if let pending = pendingError, BrowserURLPolicy.sameAddress(url, pending.address) {
                pendingError = nil
                showError(pending.message, at: url)
            } else if let errorAddress, !BrowserURLPolicy.sameAddress(url, errorAddress), !url.hasPrefix("chrome-error:") {
                // A page committed (a move, history.pushState): the failure was another page's.
                clearError()
            }
        case .title(_, let title):
            self.title = title
        case .loading(_, let isLoading, let canGoBack, let canGoForward):
            self.isLoading = isLoading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            if isLoading {
                // A failure is only another move's once a page commits (below): the error page's own
                // follow-up load (`loading` → -3 → done) keeps it. What waited of an earlier move goes.
                pendingError = nil
            } else if let pending = pendingError {
                // The move failed before it committed and the earlier page is still shown (a 204, a
                // download, a refused scheme): no card over a page that works.
                pendingError = nil
                showNotice(L10n.format("Could not open %@.", Self.shortAddress(pending.address)))
            }
        case .loadError(_, let url, let code, let message) where code != -3 && !Self.isCertificateError(code):
            // A certificate error is left to Chromium's own warning page, as in Chrome: it says what is
            // wrong and, where the error allows, lets the person go on (Advanced, then Proceed).
            let text = "\(message) (\(code))\n\(url)"
            if BrowserURLPolicy.sameAddress(tab?.currentURL, url) {
                showError(text, at: url)
            } else if isLoading {
                pendingError = (url, text)
            }
            // A failure reported once nothing loads belongs to a move already replaced: it is dropped.
        case .loadEnd(_, let url, let status):
            if status == 0, let pending = pendingError, BrowserURLPolicy.sameAddress(url, pending.address) {
                // Chromium committed its error page for the failed address (it reports no address
                // change for it, only this load end with no HTTP status).
                pendingError = nil
                showError(pending.message, at: url)
            } else if status > 0 || (errorAddress.map { !BrowserURLPolicy.sameAddress(url, $0) } ?? false && !url.hasPrefix("chrome-error:")) {
                // A page answered (a reload that worked, another page): it is no longer unavailable.
                clearError()
            }
        case .navigationBlocked(_, let url):
            showNotice(L10n.format("Blocked %@: only http, https, file, about and data addresses open here.", url))
        case .filledValueBlocked:
            showNotice(L10n.string("The page tried to put the filled password in its address. Yardlet stopped it, so the page did not move."))
        case .pageCrashed:
            // The crash shows instead (`crash`); a load error before it was the ended page's.
            clearError()
        case .javaScriptDialog, .javaScriptDialogReset, .fileDialog, .dialogClosed:
            if let tab {
                showJavaScriptDialog(tab.javaScriptDialog)
                showFileDialog(of: tab)
            }
        case .permissionPrompt, .permissionPromptDismissed:
            permissionPrompt = tab?.permissionPrompt
        case .externalAppHandled, .newDocument, .newWindow:
            if externalAppQuestion != tab?.externalAppQuestion {
                externalAppQuestion = tab?.externalAppQuestion
                alwaysAllowExternalApp = false
            }
            blockedPopups = tab?.blockedPopups ?? []
        case .download(_, let download):
            record(download)
        case .findResult(_, let result):
            findResult = result
        case .accessibilityTree, .accessibilityLocations, .scrollOffset:
            accessibility?.handle(event)
        case .failed(let message, let failed, let limit):
            // The tab could not open (Try again opens it again in its place), or the host failed as a whole.
            errorMessage = failed == nil ? message : Self.message(for: BrowserTabOpenFailure(message: message, limit: limit))
            errorAddress = nil
        case .terminated(let reason):
            picker = nil
            isPickingElement = false
            javaScriptDialog = nil
            fileDialog = nil
            fileChooser.dismiss()
            stopAccessibility(sendingDisable: false)
            tab = nil
            view?.tabID = nil
            view?.clear()
            isLoading = false
            permissionPrompt = nil
            externalAppQuestion = nil
            blockedPopups = []
            errorMessage = L10n.format("The browser process ended (%@).", reason)
        default:
            break
        }
        eventObserver?(event)
    }

    // MARK: Accessibility

    private func startAccessibility(tab: BrowserTab, view: BrowserHostView) {
        stopAccessibility(sendingDisable: true)
        let bridge = BrowserAccessibilityBridge(tab: tab, view: view, idleTimeout: Self.accessibilityIdleTimeout)
        accessibility = bridge
        view.accessibilitySource = bridge
        bridge.start()
    }

    private func stopAccessibility(sendingDisable: Bool) {
        accessibility?.stop(sendingDisable: sendingDisable)
        if view?.accessibilitySource === accessibility { view?.accessibilitySource = nil }
        accessibility = nil
    }

    /// How long the page's accessibility tree stays on after the last accessibility query while
    /// VoiceOver is off.
    static var accessibilityIdleTimeout: Duration {
#if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-accessibility-idle=") }),
           let seconds = Double(argument.dropFirst("--ui-fixture-browser-accessibility-idle=".count)) {
            return .milliseconds(Int(seconds * 1000))
        }
#endif
        return .seconds(60)
    }

    private func showError(_ message: String, at address: String) {
        errorMessage = message
        errorAddress = address
    }

    private func clearError() {
        errorMessage = nil
        errorAddress = nil
        pendingError = nil
    }

    /// An address as a notice names it: a web page's host, else the whole address.
    static func shortAddress(_ address: String) -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty else { return address }
        return host
    }

    /// As Chrome's address field: one the person is typing in keeps what they typed; one only focused
    /// (a new tab waiting for an address) follows the page.
    private func showAddress(_ url: String) {
        guard !isEditingAddress || addressInput == placedAddress else { return }
        placeAddress(url)
    }

    private func placeAddress(_ url: String) {
        addressInput = Self.shownAddress(url)
        placedAddress = addressInput
    }

    private static func shownAddress(_ url: String) -> String {
        url == "about:blank" ? "" : url
    }

    private func showNotice(_ text: String) {
        showVaultNotice(text)
    }

    /// The notice over the page, for a while (the vault's words use it too).
    func showVaultNotice(_ text: String, for duration: Duration = .seconds(6)) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func agentUsedBrowser() {
        isAgentDriving = true
        agentIndicatorTask?.cancel()
        agentIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isAgentDriving = false
        }
    }

    private func record(_ download: BrowserDownload) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index] = download
        } else {
            downloads.append(download)
            if downloads.count > 3 { downloads.removeFirst(downloads.count - 3) }
        }
        MacBrowserHost.shared.downloadFinished(download)
    }

    // MARK: Dialogs

    /// Answers the page's permission prompt: Chromium keeps an allow or a block for the site.
    func answerPermission(_ result: BrowserPermissionResult) {
        tab?.answerPermission(result)
        permissionPrompt = nil
    }

    /// The person's answer to "Open ‹app›?": Open opens the app (and keeps "Always allow" when checked), Cancel
    /// does nothing.
    func answerExternalApp(open: Bool) {
        tab?.answerExternalApp(open: open, alwaysAllow: alwaysAllowExternalApp)
        externalAppQuestion = nil
        alwaysAllowExternalApp = false
    }

    /// Opens a blocked pop-up from Chrome's list: another tab of the task, in front.
    func openBlockedPopup(_ url: String) {
        guard let tab else { return }
        client.openBlockedPopup(url, from: tab)
        blockedPopups = tab.blockedPopups
    }

    /// "Open ‹app›?" in Chrome's words: who asks, and what the box would allow.
    static func externalAppText(_ question: BrowserExternalAppQuestion) -> (title: String, message: String, alwaysAllow: String) {
        let site = URL(string: question.origin).map { url in
            (url.scheme == "https" ? "" : (url.scheme ?? "") + "://") + (url.host() ?? question.origin) + (url.port.map { ":\($0)" } ?? "")
        } ?? question.origin
        return (L10n.format("Open %@?", question.app),
                question.origin.isEmpty ? L10n.string("A website wants to open this application.")
                    : L10n.format("%@ wants to open this application.", question.origin),
                L10n.format("Always allow %@ to open links of this type in the associated app", site))
    }

    /// Chromium's certificate errors (`net::IsCertificateError`: ERR_CERT_COMMON_NAME_INVALID -200 down to
    /// ERR_CERT_END -220, exclusive, and ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN -150), for which it shows its
    /// "Your connection is not private" page.
    static func isCertificateError(_ code: Int) -> Bool {
        (code <= -200 && code > -220) || code == -150
    }

    /// The bar's sentence, in Chrome's words: who asks, and for what.
    static func permissionText(_ prompt: BrowserPermissionPrompt) -> String {
        let names: [String: String] = [
            "notifications": "Show notifications", "geolocation": "Know your location",
            "clipboard": "See text and images copied to the clipboard", "multipleDownloads": "Download multiple files",
            "storageAccess": "Use cookies and site data from another site",
            "topLevelStorageAccess": "Use cookies and site data from another site",
            "localFonts": "Use the fonts on this Mac", "windowManagement": "Manage windows on all your displays",
            "localNetworkAccess": "Connect to devices on your local network",
            "localNetwork": "Connect to devices on your local network",
            "loopbackNetwork": "Connect to apps on this Mac", "fileSystemAccess": "Edit files on this Mac",
            "camera": "Use your camera", "microphone": "Use your microphone",
            "midiSysex": "Control and reprogram your MIDI devices", "idleDetection": "Know when you're using this Mac"
        ]
        var seen = Set<String>()
        let wants = prompt.permissions.map { names[$0].map(L10n.string) ?? $0 }.filter { seen.insert($0).inserted }
        let origin = URL(string: prompt.origin).map { url in
            (url.host() ?? prompt.origin) + (url.port.map { ":\($0)" } ?? "")
        } ?? prompt.origin
        return L10n.format("%@ wants to: %@", origin, wants.joined(separator: ", "))
    }

    /// Shows the tab's JavaScript dialog over the page, or none.
    private func showJavaScriptDialog(_ dialog: BrowserJavaScriptDialog?) {
        guard dialog != javaScriptDialog else { return }
        javaScriptDialog = dialog
        dialogText = dialog?.defaultPrompt ?? ""
        dialogTakesKeyboard = dialog != nil && view?.hasKeyboardFocus == true
    }

    /// The person's answer to the dialog over the page: OK (Leave, Reload), or Cancel.
    func answerJavaScriptDialog(accept: Bool) {
        guard let tab, let dialog = javaScriptDialog else { return }
        let hadKeyboard = dialogTakesKeyboard
        tab.send(.javaScriptDialogResult(tab: tab.id, dialog: dialog.id, accepted: accept,
                                         text: dialog.kind == .prompt ? dialogText : nil))
        showJavaScriptDialog(tab.javaScriptDialog)
        // The page has the keyboard again, as when Chrome's dialog closes.
        if hadKeyboard, let view { view.window?.makeFirstResponder(view) }
    }

    /// The dialog's title, in Chrome's words, with the asking page's host so a page cannot pose as Yardlet; a page with
    /// no host (a `data:` or `file:` page) is "This page", as Chrome names it, rather than its whole address.
    static func dialogTitle(_ dialog: BrowserJavaScriptDialog) -> String {
        if dialog.kind == .beforeUnload {
            return dialog.isReload ? L10n.string("Reload site?") : L10n.string("Leave site?")
        }
        let host = URL(string: dialog.origin)?.host() ?? ""
        return host.isEmpty ? L10n.string("This page says") : L10n.format("%@ says", host)
    }

    /// Shows the tab's file chooser: one the person's input opened opens over the panel, one the agent's waits in a bar.
    private func showFileDialog(of tab: BrowserTab) {
        if fileDialog != tab.fileDialog { fileDialog = tab.fileDialog }
        if fileDialogByAgent != tab.fileDialogByAgent { fileDialogByAgent = tab.fileDialogByAgent }
        guard let dialog = tab.fileDialog else { return fileChooser.dismiss() }
        if fileChooser.presented != dialog.id, !tab.fileDialogByAgent { chooseFile() }
    }

    /// Opens the page's waiting file chooser over this panel; the person's files, or Cancel, go back to the page.
    func chooseFile() {
        guard let tab, let dialog = tab.fileDialog, let view, view.window != nil, !isPanelOccluded else { return }
#if DEBUG
        if fileDialogOverride { return }
#endif
        let tabID = tab.id
        fileChooser.present(dialog, over: view) { [weak tab] paths in
            guard let tab, tab.fileDialog?.id == dialog.id else { return }
            tab.send(.fileDialogResult(tab: tabID, dialog: dialog.id, paths: paths))
        }
    }

    /// The bar's Cancel for a chooser the agent's input opened: the page hears Cancel.
    func cancelFileDialog() {
        guard let tab, let dialog = tab.fileDialog else { return }
        tab.send(.fileDialogResult(tab: tab.id, dialog: dialog.id, paths: nil))
    }

    /// What the error card says of a tab the host could not open.
    static func message(for failure: BrowserTabOpenFailure) -> String {
        failure.limit != nil
            ? L10n.string("The browser has too many tabs open. Close a tab in this or another task, then try again.")
            : L10n.format("This tab could not open: %@", failure.message)
    }

    private static func message(for error: Error) -> String {
        switch error as? BrowserURLPolicy.AddressError {
        case .blockedScheme(let scheme):
            L10n.format("Blocked %@: only http, https, file, about and data addresses open here.", scheme + ":")
        case .empty, .invalid, .none:
            L10n.string("Enter a valid address.")
        }
    }
}

/// One of a task's side-panel browser tabs. The pane stays while the panel moves between browser tabs:
/// its controller shows the next tab in the same view, so the page keeps the keyboard.
struct BrowserHostPane: View {
    let workspaceURL: URL
    /// The side panel's actions: a new browser tab, closing one (this tab's ✕ and ⌘W), showing one.
    let onNewTab: () -> Void
    let onCloseTab: (UUID) -> Void
    let onShowTab: (UUID) -> Void
    /// The task's composer takes a picked element; nil leaves the toolbar without the picking button.
    let onPickElement: ((BrowserComment) -> Void)?
    @State private var controller: BrowserHostPaneController
    @FocusState private var isAddressFocused: Bool
    @FocusState private var isFindFocused: Bool
    /// The key button and the save offer follow the vault's items.
    @ObservedObject private var vault = MacAgentToolService.shared.vault

    init(session: UUID, key: UUID, workspace: TaskWorkspaceState, client: BrowserHostClient, workspaceURL: URL,
         onNewTab: @escaping () -> Void, onCloseTab: @escaping (UUID) -> Void, onShowTab: @escaping (UUID) -> Void,
         onPickElement: ((BrowserComment) -> Void)? = nil) {
        self.workspaceURL = workspaceURL
        self.onNewTab = onNewTab
        self.onCloseTab = onCloseTab
        self.onShowTab = onShowTab
        self.onPickElement = onPickElement
        _controller = State(initialValue: BrowserHostPaneController(session: session, key: key, workspace: workspace,
                                                                    client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: BrowserTabTitle.make(
                    pageTitle: controller.title.isEmpty
                        ? controller.workspace.browserTabs.tab(controller.key)?.title ?? "" : controller.title,
                    address: controller.tab?.currentURL ?? controller.workspace.browserTabs.tab(controller.key)?.address),
                systemName: "globe",
                favicon: controller.favicon,
                isLoading: controller.isLoading,
                workspaceURL: workspaceURL,
                status: statusText,
                statusTint: controller.errorMessage == nil && !controller.isUnresponsive && controller.crash == nil
                    ? .secondary : .red,
                onClose: { onCloseTab(controller.key) }
            ) {
                if controller.isVaultFilling {
                    Label(L10n.string("Passwords"), systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .help(L10n.string("Yardlet's password manager filled a sign-in for the agent"))
                        .accessibilityLabel(L10n.string("Yardlet's password manager filled a sign-in for the agent"))
                } else if controller.isAgentDriving {
                    Label(L10n.string("Agent"), systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .help(L10n.string("The agent is using this browser"))
                        .accessibilityLabel(L10n.string("The agent is using this browser"))
                }
                if controller.hasTab {
                    settingsMenu
                    ParityIconButton(systemName: "arrow.up.forward.app", help: L10n.string("Open externally")) {
                        controller.openExternally()
                    }
                }
            }
            toolbar
            if controller.isFindVisible { findBar }
            // The page keeps its size while it loads, a notice comes and goes or it stops responding:
            // each resize lays the page out again, and its next frame comes late on a busy Mac, so these
            // lie over the page instead of pushing it. Loading shows on the tab and the Stop button, as
            // in Chrome and the Codex app.
            ZStack(alignment: .top) {
                BrowserHostViewRepresentable(controller: controller)
                if !controller.hasTab, controller.errorMessage == nil {
                    emptyState
                }
                if controller.isUnresponsive {
                    // Its bar over the page says so; the page stays.
                } else if let crash = controller.crash {
                    errorState(title: L10n.string("This page crashed"),
                               message: L10n.format("%@ ended unexpectedly. Error code: %@",
                                                    BrowserHostPaneController.shortAddress(controller.tab?.currentURL ?? ""),
                                                    crash.errorCode),
                               action: L10n.string("Reload"))
                } else if let errorMessage = controller.errorMessage {
                    errorState(title: L10n.string("Page unavailable"), message: errorMessage, action: L10n.string("Try again"))
                }
                VStack(spacing: 0) {
                    if let handoff = controller.handoff { handoffBar(handoff) }
                    if controller.isUnresponsive { unresponsiveBar }
                    if let prompt = controller.permissionPrompt { permissionBar(prompt) }
                    if let question = controller.externalAppQuestion { externalAppBar(question) }
                    if let chooser = controller.fileDialog, controller.fileDialogByAgent { fileChooserBar(chooser) }
                    if let offer = controller.vaultOffer { vaultOfferBar(offer) }
                    if let offer = controller.vaultSetupOffer { vaultSetupBar(offer) }
                    if let offer = controller.vaultCodeOffer { vaultCodeBar(offer) }
                    if let offer = controller.vaultPasswordOffer { vaultPasswordBar(offer) }
                    if let notice = controller.notice {
                        Label(notice, systemImage: "hand.raised")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ParityTheme.subtleFill)
                            .background(.background)
                            .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
                    }
                }
                if let dialog = controller.javaScriptDialog {
                    BrowserJavaScriptDialogView(dialog: dialog, controller: controller)
                        .id(dialog.id)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            if !controller.downloads.isEmpty { downloadList }
        }
        .taskFocus(.browser, isFocused: $isAddressFocused)
        .onChange(of: controller.isEditingAddress) { _, editing in
            if editing { isAddressFocused = true }
        }
        .onChange(of: isAddressFocused) { _, focused in controller.addressFocusChanged(focused) }
        .overlayPreferenceValue(BrowserAddressFieldBounds.self) { field in
            // Chrome's dropdown, under the address field and over the page, from the field's start to the panel's
            // edge so that a narrow panel still shows titles and addresses.
            if let field, isAddressFocused, controller.autocomplete.isOpen {
                GeometryReader { proxy in
                    let bounds = proxy[field]
                    BrowserAddressSuggestionList(autocomplete: controller.autocomplete,
                                                 onOpen: { controller.openSuggestion(at: $0) },
                                                 onRemove: { controller.removeSuggestion(at: $0) })
                        .frame(width: max(bounds.width, proxy.size.width - bounds.minX - 10))
                        .offset(x: bounds.minX, y: bounds.maxY + 4)
                }
            }
        }
        .onChange(of: controller.isFindVisible) { _, visible in if visible { isFindFocused = true } }
        .sheet(item: $controller.vaultDraft) { draft in
            // "Add to Password Manager…" from the page's menu: a new item for this site.
            VaultItemSheet(vault: vault, item: nil, draftSites: draft.sites, draftUsername: draft.username) {
                controller.vaultDraft = nil
            }
        }
        .sheet(item: $controller.loginImport) { request in
            BrowserLoginImportSheet(request: request) { profile, sites in
                try await controller.importLogins(from: profile, sites: sites)
            } onDone: {
                controller.loginImport = nil
            }
        }
        .onAppear {
            controller.onNewTab = onNewTab
            controller.onCloseTab = onCloseTab
            controller.onShowTab = onShowTab
            controller.onPickElement = onPickElement
        }
    }

    /// The Claude app's Browser pane settings menu and its Viewport submenu: the panel's own size (Responsive), two
    /// desktop sizes, a phone and a tablet, and the size in use when it is none of them; one the agent set says so.
    private var settingsMenu: some View {
        Menu {
            Menu(L10n.string("Viewport")) {
                Picker(L10n.string("Viewport"), selection: viewportSelection) {
                    Text(viewportTitle(L10n.string("Responsive"), id: "responsive")).tag("responsive")
                    ForEach(Self.viewportPresets, id: \.preset.id) { item in
                        Text(viewportTitle(item.title, id: item.preset.id)).tag(item.preset.id)
                    }
                    if let emulation = controller.emulation, emulation.preset == nil {
                        Text(viewportTitle(L10n.format("Custom (%@)", Self.size(emulation.width, emulation.height)), id: "custom"))
                            .tag("custom")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Browser settings"))
        .help(L10n.string("Browser settings"))
    }

    private static let viewportPresets: [(title: String, preset: BrowserViewportEmulation.Preset)] = [
        (size(1280, 800), BrowserViewportEmulation.laptop),
        (size(1024, 768), BrowserViewportEmulation.computer),
        (L10n.format("Mobile (%@)", size(375, 812)), BrowserViewportEmulation.mobile),
        (L10n.format("Tablet (%@)", size(768, 1024)), BrowserViewportEmulation.tablet)
    ]

    private static func size(_ width: Int, _ height: Int) -> String {
        L10n.format("%@ × %@", String(width), String(height))
    }

    /// The selected row says when the agent chose it, as the Claude app's "Set by Claude".
    private func viewportTitle(_ title: String, id: String) -> String {
        guard controller.emulation?.owner == .agent, viewportSelection.wrappedValue == id else { return title }
        return L10n.format("%@ · Set by the agent", title)
    }

    private var viewportSelection: Binding<String> {
        Binding {
            guard let emulation = controller.emulation else { return "responsive" }
            return emulation.preset?.id ?? "custom"
        } set: { id in
            guard id != "custom" else { return }
            controller.setViewport(Self.viewportPresets.first { $0.preset.id == id }?.preset)
        }
    }

    /// The agent handed this tab to the person (`browser_handoff`): what it asks, and the answers it waits for.
    private func handoffBar(_ handoff: BrowserHandoff) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("The agent handed this tab to you"))
                    .font(.callout.weight(.semibold))
                Text(handoff.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(L10n.string("Decline")) { controller.answerHandoff(.declined) }
                .controlSize(.small).parityPointer()
            Button(L10n.string("I'm done")) { controller.answerHandoff(.done) }
                .controlSize(.small).parityProminentButton().parityPointer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// Chrome's "Page Unresponsive", with its Wait and a Reload in place of Exit pages.
    private var unresponsiveBar: some View {
        HStack(spacing: 8) {
            Label(L10n.string("Page Unresponsive"), systemImage: "hourglass")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 4)
            Button(L10n.string("Wait")) { controller.waitForUnresponsivePage() }
                .controlSize(.small).parityPointer()
            Button(L10n.string("Reload")) { controller.reloadUnresponsivePage() }
                .controlSize(.small).parityPointer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ParityIconButton(systemName: "chevron.left", help: L10n.string("Back")) { controller.navigate(.back) }
                    .disabled(!controller.canGoBack)
                ParityIconButton(systemName: "chevron.right", help: L10n.string("Forward")) { controller.navigate(.forward) }
                    .disabled(!controller.canGoForward)
                ParityIconButton(
                    systemName: controller.isLoading ? "xmark" : "arrow.clockwise",
                    help: controller.isLoading ? L10n.string("Stop") : L10n.string("Reload")
                ) {
                    controller.navigate(controller.isLoading ? .stop : .reload)
                }
                .disabled(!controller.hasTab)
            }
            TextField(L10n.string("Search Google or type a URL"), text: $controller.addressInput)
                .focused($isAddressFocused)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                // Submitting gives the page the keyboard (`submitAddress`); a focus change here would take
                // it back to the window.
                .onSubmit { controller.submitAddress() }
                .onChange(of: controller.addressInput) { old, text in controller.addressTextChanged(from: old, to: text) }
                .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
                    controller.addressSelectionChanged(in: note.object)
                }
                // Chrome's keys for its dropdown; each passes on to the field while the suggestions are closed.
                .onKeyPress(.downArrow) { controller.moveSuggestion(by: 1) ? .handled : .ignored }
                .onKeyPress(.upArrow) { controller.moveSuggestion(by: -1) ? .handled : .ignored }
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: [.down, .repeat]) { press in
                    let back = press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")
                    return controller.moveSuggestion(by: back ? -1 : 1) ? .handled : .ignored
                }
                .onKeyPress(.deleteForward, phases: .down) { press in
                    press.modifiers.contains(.shift) && controller.removeSuggestion() ? .handled : .ignored
                }
                .onExitCommand { controller.escapeAddress() }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(ParityTheme.separator) }
                .anchorPreference(key: BrowserAddressFieldBounds.self, value: .bounds) { $0 }
            if !controller.blockedPopups.isEmpty { blockedPopupsMenu }
            ParityIconButton(systemName: "arrow.right", help: L10n.string("Open")) { controller.submitAddress() }
            .disabled(controller.addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let saved = vault.isEnabled ? controller.vaultItemsForPage(controller.tab?.currentURL) : []
            if !saved.isEmpty {
                // Chrome's address-field key: the sign-ins saved for this site, filled for the person.
                Menu {
                    ForEach(saved) { item in
                        Button(item.username.isEmpty ? item.name : "\(item.name) · \(item.username)") {
                            controller.fillForPerson(item)
                        }
                    }
                } label: {
                    Image(systemName: "key")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.string("Fill a saved sign-in"))
                .accessibilityLabel(L10n.string("Fill a saved sign-in"))
            }
            if onPickElement != nil { pickElementButton }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(ParityTheme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    /// DevTools' "Select an element", for the task's next message; lit while the panel picks.
    private var pickElementButton: some View {
        let help = controller.isPickingElement ? L10n.string("Stop selecting (Esc)")
            : L10n.string("Select an element to attach to your message")
        return Button { controller.togglePickingElement() } label: {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(controller.isPickingElement ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background { Circle().fill(controller.isPickingElement ? ParityTheme.selectedFill : .clear) }
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(!controller.hasTab)
        .help(help)
        .accessibilityLabel(L10n.string("Select an element"))
        .accessibilityHint(help)
        .accessibilityAddTraits(controller.isPickingElement ? .isSelected : [])
    }

    /// Chrome's permission bubble, as a bar over the page: Block, Allow, or close it unanswered.
    private func permissionBar(_ prompt: BrowserPermissionPrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            Text(BrowserHostPaneController.permissionText(prompt))
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.string("Block")) { controller.answerPermission(.block) }
                .controlSize(.small)
            Button(L10n.string("Allow")) { controller.answerPermission(.allow) }
                .controlSize(.small)
            ParityIconButton(systemName: "xmark", help: L10n.string("Close")) { controller.answerPermission(.dismiss) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// Chrome's "Open ‹app›?" for another app's address, as a bar over the page like the permission bubble's:
    /// who asks, Chrome's "Always allow" box where Chrome offers it, Cancel and Open ‹app›.
    private func externalAppBar(_ question: BrowserExternalAppQuestion) -> some View {
        let text = BrowserHostPaneController.externalAppText(question)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title).font(.callout.weight(.semibold))
                Text(text.message).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if question.offersAlwaysAllow {
                    Toggle(text.alwaysAllow, isOn: $controller.alwaysAllowExternalApp)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(L10n.string("Cancel")) { controller.answerExternalApp(open: false) }
                .controlSize(.small)
            Button(L10n.format("Open %@", question.app)) { controller.answerExternalApp(open: true) }
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// A file chooser the agent's input opened, waiting in its tab: the agent answers it (`browser_file_upload`), or the
    /// person opens it here, rather than the system's panel opening over whatever the person is doing.
    private func fileChooserBar(_ chooser: BrowserFileDialog) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(chooser.mode == .save ? L10n.string("The page asks where to save a file")
                                           : L10n.string("The page asks for a file"))
                    .font(.callout.weight(.semibold))
                Text(L10n.string("The agent's action opened it. The agent can answer it, or you can choose."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Cancel")) { controller.cancelFileDialog() }
                .controlSize(.small)
            Button(chooser.mode == .save ? L10n.string("Choose Location…") : L10n.string("Choose File…")) {
                controller.chooseFile()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// Chrome's "Pop-ups blocked" in the address field: the pop-ups the page opened without a click, each of
    /// which opens from here.
    private var blockedPopupsMenu: some View {
        Menu {
            Section(L10n.string("Pop-ups blocked")) {
                ForEach(controller.blockedPopups, id: \.self) { url in
                    Button(url) { controller.openBlockedPopup(url) }
                }
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("Pop-ups were blocked on this page."))
        .accessibilityLabel(L10n.string("Pop-ups were blocked on this page."))
    }

    /// Chrome's save bubble, as a bar over the page: the person just signed in with a password the vault
    /// does not have.
    private func vaultOfferBar(_ offer: BrowserVaultSaveOffer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key").foregroundStyle(.secondary)
            Text(offer.updates == nil
                 ? L10n.format("Save the password for %@?", VaultSite.host(of: offer.origin))
                 : L10n.format("Update the saved password for %@?", VaultSite.host(of: offer.origin)))
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L10n.string("Not for This Site")) { controller.neverSaveHere() }
                .controlSize(.small)
            Button(offer.updates == nil ? L10n.string("Save") : L10n.string("Update")) { controller.acceptVaultOffer() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    /// The suggestion at a code field that password managers show, as a bar over the page: the site's
    /// item has a two-factor code and the page asks for one. A code with no site yet, offered by its name,
    /// says the site it keeps.
    private func vaultCodeBar(_ offer: BrowserVaultCodeOffer) -> some View {
        vaultBar(systemName: "number") {
            if let site = offer.newSite {
                Text(offer.items.count == 1
                     ? L10n.format("Fill the two-factor code from “%@” and link it to %@?", offer.items[0].name, site)
                     : L10n.format("Fill a two-factor code and link it to %@?", site))
            } else {
                Text(offer.items.count == 1
                     ? L10n.format("Fill the two-factor code from “%@”?", offer.items[0].name)
                     : L10n.format("Fill a two-factor code for %@?", VaultSite.host(of: offer.origin)))
            }
        } actions: {
            Button(L10n.string("Not Now")) { controller.vaultCodeOffer = nil }
                .controlSize(.small)
            if offer.items.count == 1 {
                Button(L10n.string("Fill Code")) { controller.fillCodeForPerson(offer.items[0]) }
                    .controlSize(.small)
            } else {
                Menu(L10n.string("Fill Code")) {
                    ForEach(offer.items) { item in
                        Button(item.username.isEmpty ? item.name : "\(item.name) · \(item.username)") {
                            controller.fillCodeForPerson(item)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    /// The strong password suggestion at a new-password field that Chrome and Safari show, as a bar over the
    /// page. The password is made when the person takes it, so the bar never holds one.
    private func vaultPasswordBar(_ offer: BrowserVaultPasswordOffer) -> some View {
        vaultBar(systemName: "key") {
            Text(L10n.format("Use a strong password for %@? The password manager saves it.", VaultSite.host(of: offer.origin)))
        } actions: {
            Button(L10n.string("Not Now")) { controller.vaultPasswordOffer = nil }
                .controlSize(.small)
            Button(L10n.string("Use Strong Password")) { controller.useStrongPassword() }
                .controlSize(.small)
        }
    }

    /// A site's two-factor setup QR code (or an authenticator app's export) on the page, offered for the
    /// vault, as Safari offers setting up a code from a QR code's image.
    private func vaultSetupBar(_ offer: BrowserVaultSetupOffer) -> some View {
        vaultBar(systemName: "qrcode") {
            Text(setupQuestion(offer))
        } actions: {
            Button(L10n.string("Not Now")) { controller.dismissSetupOffer() }
                .controlSize(.small)
            if offer.isImport {
                Button(L10n.string("Import")) { controller.acceptSetupOffer() }
                    .controlSize(.small)
            } else if offer.choices.count > 1 {
                // Saves into the default target; the arrow chooses another item.
                Menu {
                    ForEach(offer.choices) { item in
                        Button(item.username.isEmpty ? item.name : "\(item.name) · \(item.username)") {
                            controller.acceptSetupOffer(into: .item(item))
                        }
                    }
                    Divider()
                    Button(L10n.string("New Item")) { controller.acceptSetupOffer(into: .newItem) }
                } label: {
                    Text(L10n.string("Save"))
                } primaryAction: {
                    controller.acceptSetupOffer()
                }
                .controlSize(.small)
                .fixedSize()
            } else {
                Button(L10n.string("Save")) { controller.acceptSetupOffer() }
                    .controlSize(.small)
            }
        }
    }

    private func setupQuestion(_ offer: BrowserVaultSetupOffer) -> String {
        if offer.isImport {
            return offer.setups.count == 1
                ? L10n.format("Save the two-factor code for “%@”?", offer.setups[0].itemName)
                : L10n.format("Import %lld two-factor codes?", Int64(offer.setups.count))
        }
        let host = VaultSite.host(of: offer.origin)
        guard let target = offer.target else { return L10n.format("Save the two-factor code for %@?", host) }
        return target.hasOneTimeCode
            ? L10n.format("Replace the two-factor code in “%@” with this one?", target.name)
            : L10n.format("Save the two-factor code for %@ in “%@”?", host, target.name)
    }

    private func vaultBar<Message: View, Actions: View>(systemName: String, @ViewBuilder message: () -> Message,
                                                        @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName).foregroundStyle(.secondary)
            message()
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("Find in page"), text: $controller.findText)
                .focused($isFindFocused)
                .textFieldStyle(.plain)
                .onSubmit { controller.find() }
                .onChange(of: controller.findText) { _, _ in controller.findTextChanged() }
                .onExitCommand { controller.closeFind() }
            if let result = controller.findResult {
                Text(verbatim: result.matches == 0 ? L10n.string("No results") : "\(result.activeMatch)/\(result.matches)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ParityIconButton(systemName: "chevron.up", help: L10n.string("Previous")) { controller.find(backward: true) }
            ParityIconButton(systemName: "chevron.down", help: L10n.string("Next")) { controller.find() }
            ParityIconButton(systemName: "xmark", help: L10n.string("Close")) { controller.closeFind() }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(ParityTheme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.string("Enter an address to open a page"))
                .font(.callout.weight(.semibold))
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
    }

    private func errorState(title: String, message: String, action: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.orange)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            Button(action) { controller.retry() }
                .controlSize(.small)
                .parityPointer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            ForEach(controller.downloads, id: \.id) { download in
                HStack(spacing: 8) {
                    Image(systemName: download.state == .completed ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(download.state == .completed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: download.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: downloadStatus(download)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    switch download.state {
                    case .started, .inProgress:
                        ParityIconButton(systemName: "xmark.circle", help: L10n.string("Cancel")) { controller.cancelDownload(download) }
                    case .completed:
                        ParityIconButton(systemName: "magnifyingglass", help: L10n.string("Show in Finder")) { controller.revealDownload(download) }
                        ParityIconButton(systemName: "xmark", help: L10n.string("Close")) { controller.dismissDownload(download) }
                    case .cancelled, .interrupted:
                        ParityIconButton(systemName: "xmark", help: L10n.string("Close")) { controller.dismissDownload(download) }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
            }
        }
        .background(ParityTheme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    private func downloadStatus(_ download: BrowserDownload) -> String {
        switch download.state {
        case .started, .inProgress:
            guard download.totalBytes > 0 else {
                return ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
            }
            return L10n.format("%@ of %@", ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file),
                               ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))
        case .completed: return L10n.string("Saved to Downloads")
        case .cancelled: return L10n.string("Cancelled")
        case .interrupted: return L10n.string("Download failed")
        }
    }

    private var statusText: String? {
        BrowserHostPaneController.status(isUnresponsive: controller.isUnresponsive, isCrashed: controller.crash != nil,
                                         hasError: controller.errorMessage != nil,
                                         isLoading: controller.isLoading, hasTab: controller.hasTab)
    }
}

struct BrowserHostViewRepresentable: NSViewRepresentable {
    let controller: BrowserHostPaneController

    func makeCoordinator() -> BrowserHostPaneController { controller }

    func makeNSView(context: Context) -> BrowserHostView {
        let view = BrowserHostView(frame: .zero)
        // Attach after the first layout so a new tab starts at the panel's real size.
        DispatchQueue.main.async { controller.attach(view) }
        return view
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {}

    static func dismantleNSView(_ nsView: BrowserHostView, coordinator: BrowserHostPaneController) {
        coordinator.detach()
    }
}
