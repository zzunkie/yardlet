import Foundation
import Observation

struct TranscriptReadingBookmark: Codable, Equatable {
    var anchorID: String?
    var fraction: Double = 0
    var followsLatest = true
}

@MainActor @Observable
final class TranscriptReadingPosition {
    var bookmark = TranscriptReadingBookmark() {
        didSet { if bookmark != oldValue { onChange?() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?
}

/// What a task's area draws: the side panel's width and the terminal's height, which every task
/// shares (`TaskWorkspaceSizes`), and whether this task's side panel is expanded over the
/// conversation. Kept in each task's snapshot as it always was, so a build before the shared sizes
/// still reads it.
struct TaskWorkspacePreferences: Codable, Equatable {
    /// The width last dragged, or the width before it followed the window (`TaskWorkspaceSizes`).
    var panelWidth: Double = TaskWorkspaceSizes.defaultPanelWidth
    var terminalHeight: Double = TaskWorkspaceSizes.defaultTerminalHeight
    var isExpanded = false
    /// Where the dragged width sits between the narrowest and widest the task's area allows; nil
    /// while the width follows the Codex app's default for the area (`SidePanelWidth`).
    var panelWidthRatio: Double?
}

/// The side panel's width and the terminal's height, one pair for every task. The Codex app keeps
/// one right-panel width (`app-shell:right-panel-width:v3`) and one bottom-panel height
/// (`app-shell:bottom-panel-height`) for all its threads, and the Claude app opens a pane at the
/// width that kind of pane had last (`lastPaneFlexByKind`): a width dragged in one task is the
/// width the next task's panel opens at, rather than every task starting over at the default.
///
/// The width is kept as the Codex app keeps it, as a share of the room between the panel's narrowest
/// and widest (`panelWidthRatio`), so it follows the window; until the divider is dragged it is the
/// Codex app's default for the area (`SidePanelWidth.standard`). `panelWidth` keeps the last dragged
/// width for a build before the share, and a width a build before the share saved there is turned
/// into a share the first time the panel opens (`SidePanelWidth.resolve`).
struct TaskWorkspaceSizes: Codable, Equatable {
    /// The width every panel opened at before it followed the window, which says nothing was dragged.
    static let defaultPanelWidth: Double = 420
    /// The Codex app's bottom panel (`kko`).
    static let defaultTerminalHeight: Double = 280
    /// The height before the Codex app's, which a task saved without the person choosing it.
    static let earlierDefaultTerminalHeight: Double = 240
    /// The Codex app's bottom panel keeps at least 160 (`Eko`).
    static let minimumTerminalHeight: Double = 160

    var panelWidth: Double = defaultPanelWidth
    var terminalHeight: Double = defaultTerminalHeight
    var panelWidthRatio: Double?

    /// Within what the layout allows; a corrupt value takes its default.
    var clamped: Self {
        Self(panelWidth: panelWidth.isFinite ? min(max(300, panelWidth), 1600) : Self.defaultPanelWidth,
             terminalHeight: terminalHeight.isFinite
                ? min(max(Self.minimumTerminalHeight, terminalHeight), 1000) : Self.defaultTerminalHeight,
             panelWidthRatio: panelWidthRatio.flatMap { $0.isFinite ? min(max(0, $0), 1) : nil })
    }

    /// The sizes a task's own snapshot carries, with the earlier defaults read as nothing chosen.
    init(carriedBy layout: TaskWorkspacePreferences) {
        self.init(panelWidth: layout.panelWidth,
                  terminalHeight: layout.terminalHeight == Self.earlierDefaultTerminalHeight
                    ? Self.defaultTerminalHeight : layout.terminalHeight,
                  panelWidthRatio: layout.panelWidthRatio)
    }

    init(panelWidth: Double = defaultPanelWidth, terminalHeight: Double = defaultTerminalHeight,
         panelWidthRatio: Double? = nil) {
        self.panelWidth = panelWidth
        self.terminalHeight = terminalHeight
        self.panelWidthRatio = panelWidthRatio
    }
}

/// The shared sizes, observed by every task's area in the window.
@MainActor @Observable
final class TaskWorkspaceSizeStore {
    private(set) var sizes: TaskWorkspaceSizes
    @ObservationIgnored var onChange: (() -> Void)?

    init(_ sizes: TaskWorkspaceSizes = .init()) {
        self.sizes = sizes.clamped
    }

    func update(_ change: (inout TaskWorkspaceSizes) -> Void) {
        var next = sizes
        change(&next)
        next = next.clamped
        guard next != sizes else { return }
        sizes = next
        onChange?()
    }
}

struct TaskWorkspaceSnapshot: Codable, Equatable {
    var version = 1
    var panels = TaskSurfaceNavigationProjection.PanelState()
    var layout = TaskWorkspacePreferences()
    var transcript = TranscriptReadingBookmark()
    var codex = TranscriptReadingBookmark()
    // Optional so existing version-1 workspace snapshots retain their layout and reading position.
    var review: DiffReviewPreferences?
    var files: WorkspaceFilePreferences?
    var browser: BrowserPreviewPreferences?
    /// The session rail's folded and opened cards for this task; nil while every card keeps its
    /// default.
    var railFolds: SessionRailFolds?
    /// Which panel rules the saved panels were kept under: nil before the side panel opened to its
    /// launcher, when a panel that had never been used opened to Review on its own.
    var panelsRevision: Int?

    static let launcherPanelsRevision = 2
    /// Each browser tab is a side-panel tab of its own (2026-10-23).
    static let browserTabsPanelsRevision = 3

    /// A snapshot saved before the launcher, whose only side-panel tab is Review, most likely got it
    /// from the panel opening there on its own: it opens to the launcher instead, once. A snapshot
    /// saved before each browser tab was a side-panel tab turns its one Browser tab, which held the
    /// task's browser tabs, into a side-panel tab per browser tab, once.
    var migrated: Self {
        var next = self
        if panelsRevision == nil, panels.trailingTabs == ["diff"] {
            next.panels.trailingTabs = []
            next.panels.recentTrailingTabs = []
            if next.panels.trailingSurfaceID == "diff" {
                next.panels.trailingSurfaceID = TaskSurfaceNavigationProjection.launcherID
            }
        }
        if (panelsRevision ?? 0) < Self.browserTabsPanelsRevision, next.browser?.pages == nil {
            let legacyID = TaskSurfaceNavigationProjection.browserChoiceID
            if next.panels.trailingTabs.contains(legacyID) || next.panels.trailingSurfaceID == legacyID {
                let saved = next.browser ?? .init()
                let (pages, fronted) = saved.legacyPages
                next.panels = TaskSurfaceNavigationProjection.expandingLegacyBrowserTab(
                    in: next.panels, keys: pages.map(\.key), fronted: fronted)
                next.browser = BrowserPreviewPreferences(address: saved.address, tabs: saved.tabs,
                                                         selectedTab: saved.selectedTab, pages: pages)
            }
        }
        return next
    }
}

/// A terminal tab's title: the name the person gave it, else its folder's name, numbered from the
/// second tab on in the order the tabs opened ("yardlet", "yardlet 2"), so each keeps its title while
/// others open and close.
@MainActor
enum TerminalTabTitle {
    static func defaultTitle(of shell: NativeTerminalSession) -> String {
        let folder = shell.workspaceURL.lastPathComponent
        return shell.number > 1 ? "\(folder) \(shell.number)" : folder
    }

    static func titles(for shells: [NativeTerminalSession]) -> [ObjectIdentifier: String] {
        Dictionary(shells.map { (ObjectIdentifier($0), $0.name ?? defaultTitle(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The tab's id in the header's strip.
    static func tabID(_ shell: NativeTerminalSession) -> String {
        "terminal:" + shell.id.uuidString
    }
}

/// A command handed to a task's terminal to run once. Each click is its own request, so the same
/// command handed twice runs twice.
struct TerminalCommandRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let command: String

    init(id: UUID = UUID(), command: String) {
        self.id = id
        self.command = command
    }
}

enum TaskWorkspaceSelection: Codable, Equatable {
    case home
    case task(UUID)
}

@MainActor @Observable
final class TaskWorkspaceState {
    private(set) var panels: TaskSurfaceNavigationProjection.PanelState
    /// The side panel's width and the terminal's height, shared with every other task.
    let sizes: TaskWorkspaceSizeStore
    /// This task's side panel is expanded over the conversation.
    private var isExpanded: Bool { didSet { if isExpanded != oldValue { onChange?() } } }
    /// What the task's area draws: the shared sizes with this task's expansion. Dragging a divider
    /// sets the shared sizes.
    var layout: TaskWorkspacePreferences {
        get {
            TaskWorkspacePreferences(panelWidth: sizes.sizes.panelWidth, terminalHeight: sizes.sizes.terminalHeight,
                                     isExpanded: isExpanded, panelWidthRatio: sizes.sizes.panelWidthRatio)
        }
        set {
            sizes.update {
                $0.panelWidth = newValue.panelWidth
                $0.terminalHeight = newValue.terminalHeight
                $0.panelWidthRatio = newValue.panelWidthRatio
            }
            isExpanded = newValue.isExpanded
        }
    }
    var review: DiffReviewPreferences { didSet { if review != oldValue { onChange?() } } }
    /// The side chat open in the side panel. A side chat is temporary, as the Codex app's: never
    /// saved, and ended when its tab closes (`onSideChatClose`) or Yardlet quits.
    var sideChatSessionID: UUID?
    /// The session rail's folds for this task, kept with its panels.
    var railFolds: SessionRailFolds { didSet { if railFolds != oldValue { onChange?() } } }
    /// What the side panel shows over its tabs for an agent or a background task. Never saved.
    private(set) var panelDetail: TaskPanelDetail?
    /// Whether a Git repository holds one of the task's folders, read as its side panel shows, which
    /// says whether the launcher and the + menu offer Review (the Codex app offers Changes only in a
    /// repository). Nil until read; never saved.
    var hasRepository: Bool?
    /// The tab the detail covered, to return to when it closes.
    @ObservationIgnored private var panelDetailReturnID: String?
    let transcript = TranscriptReadingPosition()
    let codex = TranscriptReadingPosition()
    /// Kept for panel return during this task; opening an original child log remains explicit.
    @ObservationIgnored private var subtaskReadings: [String: TranscriptReadingPosition] = [:]
    let keyboardFocus = TaskKeyboardFocus()
    /// The conversation's find bar. Kept for this app session only, never saved.
    let conversationFind = ConversationFindModel()
    /// The conversation's projection and turn views, kept while the task is among the last shown
    /// (`ConversationRenderState`). Never saved.
    @ObservationIgnored let conversationRender = ConversationRenderState()
    /// The Files panel's state and the side panel's browser tabs: replaced only when a task takes over
    /// the new-task screen's (`takeOver(from:taskID:)`).
    private(set) var files: WorkspaceFilesState
    private(set) var browserTabs: TaskBrowserTabs
    /// The browser engine the task's browser tabs open in, and the observer that keeps them the side
    /// panel's tabs (`attachBrowser`); nil in a build without the engine, where each tab is a WebKit
    /// preview page.
    @ObservationIgnored var browserLink: BrowserPanelLink?
    /// The browser engine, when this build has one.
    var browserClient: BrowserHostClient? { browserLink?.client }
    /// One explicit panel-open gesture may start a new shell. This is never persisted.
    var terminalStartRequested = false
    /// The terminal's tabs, each with its shell, kept here rather than by the terminal panel, so they go
    /// on while the task is off screen or its panel hidden, and the tabs the new-task screen opened go on
    /// in the task it starts. The Claude app and the Codex app give each session or thread several
    /// terminal tabs. Never saved.
    @ObservationIgnored private var terminalTabs: [NativeTerminalSession] = []
    /// The tab the terminal panel shows.
    @ObservationIgnored private var shownTerminalTab: NativeTerminalSession?
    /// Changes when the terminal's tabs change other than by the panel drawing them: a tab opened,
    /// shown or closed, a shell that ended leaving its tab, a restart in the task's folder, or a task
    /// taking over the new-task screen's.
    private(set) var terminalRevision = 0
    /// A command a conversation card handed to the task's terminal, until the terminal has typed
    /// it. Closing the terminal or leaving the task drops it. Never persisted.
    var terminalHandoff: TerminalCommandRequest?
    @ObservationIgnored var onChange: (() -> Void)?
    /// The side chat's tab closed, which ends the side chat.
    @ObservationIgnored var onSideChatClose: (() -> Void)?

    /// - Parameter sizes: the window's shared sizes; a task shown on its own (a render, a test)
    ///   keeps the sizes its snapshot carries.
    init(snapshot: TaskWorkspaceSnapshot = .init(), sizes: TaskWorkspaceSizeStore? = nil) {
        panels = snapshot.panels
        self.sizes = sizes ?? TaskWorkspaceSizeStore(TaskWorkspaceSizes(carriedBy: snapshot.layout))
        isExpanded = snapshot.layout.isExpanded
        review = snapshot.review ?? .init()
        railFolds = snapshot.railFolds ?? SessionRailFolds()
        files = WorkspaceFilesState(preferences: snapshot.files ?? .init())
        browserTabs = TaskBrowserTabs(pages: snapshot.browser?.pages ?? [], visited: snapshot.browser?.visited ?? [])
        // A Claude subtask is not restored; a saved panel list opens the tab it leads to.
        if let shown = panels.trailingSurfaceID, !TaskSurfaceNavigationProjection.isTab(shown),
           ![TaskSurfaceNavigationProjection.sidePanelToggleID, TaskSurfaceNavigationProjection.launcherID].contains(shown) {
            panels.trailingSurfaceID = nil
        }
        panels = TaskSurfaceNavigationProjection.reconciled(panels)
        transcript.bookmark = snapshot.transcript
        codex.bookmark = snapshot.codex
        transcript.onChange = { [weak self] in self?.onChange?() }
        codex.onChange = { [weak self] in self?.onChange?() }
        files.onChange = { [weak self] in self?.onChange?() }
        browserTabs.onChange = { [weak self] in self?.onChange?() }
    }

    /// The tab the terminal panel shows: the one kept, else a new one in `folder` that starts when a
    /// panel shows it. A tab whose shell exited and that no panel showed any more has ended
    /// (`NativeTerminalSession.panelDisappeared`) and left the tabs.
    func terminal(in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) -> NativeTerminalSession {
        if let shownTerminalTab { return shownTerminalTab }
        let session = makeTerminal(in: folder, launch: launch, taskID: taskID)
        terminalTabs = [session]
        shownTerminalTab = session
        return session
    }

    /// The terminal's tabs in order, the shown one among them.
    var terminals: [NativeTerminalSession] { terminalTabs }

    /// The tab the terminal panel shows, without opening one.
    var shownTerminal: NativeTerminalSession? { shownTerminalTab }

    /// The terminal's + : a new tab in `folder`, shown, its shell started.
    @discardableResult
    func openTerminalTab(in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) -> NativeTerminalSession {
        let session = makeTerminal(in: folder, launch: launch, taskID: taskID)
        terminalTabs.append(session)
        shownTerminalTab = session
        terminalStartRequested = true
        terminalRevision += 1
        return session
    }

    func showTerminalTab(_ session: NativeTerminalSession) {
        guard session !== shownTerminalTab, terminalTabs.contains(where: { $0 === session }) else { return }
        shownTerminalTab = session
        terminalRevision += 1
    }

    /// Closing a tab ends its shell; the panel shows the tab after it, else the one before. False when
    /// no tab is left, and the panel hides.
    @discardableResult
    func closeTerminalTabs(_ sessions: [NativeTerminalSession]) -> Bool {
        for session in sessions where terminalTabs.contains(where: { $0 === session }) { session.end() }
        return !terminalTabs.isEmpty
    }

    /// "Restart in …": the shown tab's shell ends and the tab opens the next one in `folder`, keeping
    /// its place and name.
    func restartTerminal(in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) {
        let session = makeTerminal(in: folder, launch: launch, taskID: taskID)
        if let old = shownTerminalTab, let index = terminalTabs.firstIndex(where: { $0 === old }) {
            session.name = old.name
            session.number = old.number
            terminalTabs[index] = session
            old.onEnd = nil
            old.end()
        } else {
            terminalTabs.append(session)
        }
        shownTerminalTab = session
        terminalStartRequested = true
        terminalRevision += 1
    }

    /// The task is archived or deleted: its shells end with it, as the Codex app closes a thread's
    /// terminals when the thread is archived or deleted.
    func endTerminal() {
        let tabs = terminalTabs
        terminalTabs = []
        shownTerminalTab = nil
        for tab in tabs {
            tab.onEnd = nil
            tab.end()
        }
    }

    private func makeTerminal(in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) -> NativeTerminalSession {
        let session = NativeTerminalSession(workspaceURL: folder, launch: launch, taskID: taskID)
        let taken = Set(terminalTabs.map(\.number))
        session.number = (1...).first { !taken.contains($0) }!
        adoptTerminal(session)
        return session
    }

    private func adoptTerminal(_ session: NativeTerminalSession) {
        session.onEnd = { [weak self, weak session] in
            guard let self, let session else { return }
            self.terminalEnded(session)
        }
    }

    /// A shell that ended leaves its tab, closed or exited and no longer shown; the panel shows the tab
    /// after it, else the one before.
    private func terminalEnded(_ session: NativeTerminalSession) {
        guard let index = terminalTabs.firstIndex(where: { $0 === session }) else { return }
        terminalTabs.remove(at: index)
        if shownTerminalTab === session {
            shownTerminalTab = terminalTabs.isEmpty ? nil : terminalTabs[min(index, terminalTabs.count - 1)]
        }
        terminalRevision += 1
    }

    /// A task started from the new-task screen takes over its panels: their tabs, the Files and
    /// browser state, and the terminal's tabs, whose shells go on as they were (the Codex app's thread
    /// takes over its draft's tabs). The new-task screen starts over empty, as the Codex app's does
    /// with a new draft. The browser engine's tabs move separately (`AppModel.handOffDraftWorkspace`).
    func takeOver(from draft: TaskWorkspaceState, taskID: UUID) {
        let startRequested = draft.terminalStartRequested
        setPanels(draft.panels)
        terminalStartRequested = startRequested
        isExpanded = draft.isExpanded

        let files = draft.files
        let browserTabs = draft.browserTabs
        draft.replace(files: WorkspaceFilesState(), browserTabs: TaskBrowserTabs())
        replace(files: files, browserTabs: browserTabs)

        let shells = draft.terminalTabs.filter { !$0.hasEnded }
        if !shells.isEmpty {
            endTerminal()
            for shell in shells {
                shell.move(toTask: taskID)
                adoptTerminal(shell)
            }
            terminalTabs = shells
            shownTerminalTab = shells.first { $0 === draft.shownTerminalTab } ?? shells[0]
        }
        draft.terminalTabs = []
        draft.shownTerminalTab = nil
        terminalRevision += 1
        draft.terminalRevision += 1

        draft.setPanels(.init())
        draft.isExpanded = false
        draft.terminalHandoff = nil
        onChange?()
        draft.onChange?()
    }

    private func replace(files: WorkspaceFilesState, browserTabs: TaskBrowserTabs) {
        self.files.onChange = nil
        self.browserTabs.onChange = nil
        self.files = files
        self.browserTabs = browserTabs
        files.onChange = { [weak self] in self?.onChange?() }
        browserTabs.onChange = { [weak self] in self?.onChange?() }
    }

    var snapshot: TaskWorkspaceSnapshot {
        let browserKeys = TaskSurfaceNavigationProjection.browserKeys(in: panels)
        let latestBrowser = TaskSurfaceNavigationProjection.browserKey(
            inTab: TaskSurfaceNavigationProjection.latestBrowserTab(in: panels))
        return TaskWorkspaceSnapshot(panels: panels, layout: layout,
                                     transcript: transcript.bookmark, codex: codex.bookmark,
                                     review: review == .init() ? nil : review,
                                     files: files.preferences == .init() ? nil : files.preferences,
                                     browser: browserTabs.preferences(order: browserKeys, latest: latestBrowser),
                                     railFolds: railFolds.isDefault ? nil : railFolds,
                                     panelsRevision: TaskWorkspaceSnapshot.browserTabsPanelsRevision)
    }

    func setPanels(_ value: TaskSurfaceNavigationProjection.PanelState) {
        let value = TaskSurfaceNavigationProjection.reconciled(value)
        guard value != panels else { return }
        if value.isTerminalPresented && !panels.isTerminalPresented { terminalStartRequested = true }
        if !value.isTerminalPresented {
            terminalStartRequested = false
            terminalHandoff = nil
        }
        let closesSideChat = panels.trailingTabs.contains("sideChat") && !value.trailingTabs.contains("sideChat")
        panels = value
        onChange?()
        if closesSideChat { onSideChatClose?() }
        // The browser tab the panel shows is the one in front, which the agent's tools use when they
        // name no tab; the browser is told before anything else can ask it.
        frontShownBrowserTab()
    }

    /// "Run in terminal" on a command card or a code block: the shown tab runs `command` at its prompt, as
    /// the Claude app's runs what it types. A tab where a program holds the terminal (a sign-in waiting, a
    /// dev server) is left alone: another tab at its prompt shows, else a new tab opens in `folder`, as the
    /// Claude app's terminal takes a tab at its prompt and leaves one where a command runs. The click is the
    /// explicit gesture that may start a shell; the caller opens the terminal panel.
    func handOffToTerminal(_ command: String, in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) {
        if let shown = shownTerminalTab, shown.isRunningProgram {
            if let idle = terminalTabs.first(where: { $0 !== shown && $0.isAtPrompt }) {
                showTerminalTab(idle)
            } else {
                openTerminalTab(in: folder, launch: launch, taskID: taskID)
            }
        }
        terminalHandoff = TerminalCommandRequest(command: command)
        terminalStartRequested = true
    }

    /// The terminal is done with a handoff, typed or not.
    func finishTerminalHandoff(_ id: TerminalCommandRequest.ID) {
        if terminalHandoff?.id == id { terminalHandoff = nil }
    }

    /// Leaving the task leaves its terminal's shells running; nothing waits to be typed or started in
    /// them on the next visit.
    func leaveTerminal() {
        if terminalStartRequested { terminalStartRequested = false }
        if terminalHandoff != nil { terminalHandoff = nil }
    }

    /// Shows an agent's conversation or a background task's output in the side panel, over its tabs.
    func showPanelDetail(_ detail: TaskPanelDetail) {
        let shown = panels.trailingSurfaceID
        if shown != TaskPanelDetail.surfaceID, shown != "subtask" { panelDetailReturnID = shown }
        panelDetail = detail
        var next = panels
        next.trailingSurfaceID = TaskPanelDetail.surfaceID
        setPanels(next)
    }

    /// Closing the detail returns the side panel to the tab it covered, or hides the panel again.
    func closePanelDetail() {
        let returnID = panelDetailReturnID.flatMap {
            panels.trailingTabs.contains($0) || $0 == TaskSurfaceNavigationProjection.launcherID ? $0 : nil
        }
        panelDetailReturnID = nil
        panelDetail = nil
        guard panels.trailingSurfaceID == TaskPanelDetail.surfaceID else { return }
        var next = panels
        next.trailingSurfaceID = returnID
        setPanels(next)
    }

    func subtaskReading(for key: String) -> TranscriptReadingPosition {
        if let value = subtaskReadings[key] { return value }
        let value = TranscriptReadingPosition()
        subtaskReadings[key] = value
        return value
    }
}

@MainActor
protocol TaskWorkspaceRepository {
    func load(for id: UUID) -> TaskWorkspaceSnapshot?
    func save(_ snapshot: TaskWorkspaceSnapshot, for id: UUID)
    func remove(for id: UUID)
    func loadSelection() -> TaskWorkspaceSelection?
    func saveSelection(_ selection: TaskWorkspaceSelection)
    /// The sizes every task shares; nil until one was saved.
    func loadSizes() -> TaskWorkspaceSizes?
    func saveSizes(_ sizes: TaskWorkspaceSizes)
}

@MainActor
final class InMemoryTaskWorkspaceRepository: TaskWorkspaceRepository {
    var snapshots: [UUID: TaskWorkspaceSnapshot] = [:]
    var selection: TaskWorkspaceSelection?
    var sizes: TaskWorkspaceSizes?
    func load(for id: UUID) -> TaskWorkspaceSnapshot? { snapshots[id] }
    func save(_ snapshot: TaskWorkspaceSnapshot, for id: UUID) { snapshots[id] = snapshot }
    func remove(for id: UUID) { snapshots.removeValue(forKey: id) }
    func loadSelection() -> TaskWorkspaceSelection? { selection }
    func saveSelection(_ selection: TaskWorkspaceSelection) { self.selection = selection }
    func loadSizes() -> TaskWorkspaceSizes? { sizes }
    func saveSizes(_ sizes: TaskWorkspaceSizes) { self.sizes = sizes }
}

struct UserDefaultsTaskWorkspaceRepository: TaskWorkspaceRepository {
    let defaults: UserDefaults
    private let prefix = "Yardlet.taskWorkspace."
    func load(for id: UUID) -> TaskWorkspaceSnapshot? {
        guard let data = defaults.data(forKey: prefix + id.uuidString),
              let snapshot = try? JSONDecoder().decode(TaskWorkspaceSnapshot.self, from: data),
              snapshot.version == 1 else { return nil }
        return snapshot
    }
    func save(_ snapshot: TaskWorkspaceSnapshot, for id: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: prefix + id.uuidString)
    }
    func remove(for id: UUID) { defaults.removeObject(forKey: prefix + id.uuidString) }
    func loadSelection() -> TaskWorkspaceSelection? {
        guard let data = defaults.data(forKey: prefix + "selection") else { return nil }
        return try? JSONDecoder().decode(TaskWorkspaceSelection.self, from: data)
    }
    func saveSelection(_ selection: TaskWorkspaceSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: prefix + "selection")
    }
    func loadSizes() -> TaskWorkspaceSizes? {
        guard let data = defaults.data(forKey: prefix + "sizes") else { return nil }
        return try? JSONDecoder().decode(TaskWorkspaceSizes.self, from: data)
    }
    func saveSizes(_ sizes: TaskWorkspaceSizes) {
        guard let data = try? JSONEncoder().encode(sizes) else { return }
        defaults.set(data, forKey: prefix + "sizes")
    }
}

/// UI preferences are advisory and separate from the user's unsent input repository.
@MainActor
final class TaskWorkspaceStore {
    private let repository: any TaskWorkspaceRepository
    private var states: [UUID: TaskWorkspaceState] = [:]
    private var dirtyIDs = Set<UUID>()
    private var pendingSave: Task<Void, Never>?
    /// The side panel width and terminal height every task shares.
    let sizes: TaskWorkspaceSizeStore
    /// The shared sizes were saved once, or set since. Until then the first task whose snapshot
    /// carries sizes of its own seeds them, so a width dragged in a build that kept sizes per task
    /// is not lost.
    private var sizesKnown: Bool
    private var sizesDirty = false
    /// A task's side chat tab closed (`TaskWorkspaceState.onSideChatClose`).
    var onSideChatClose: ((UUID) -> Void)?

    /// The browser engine the tasks' browser tabs open in, when this build has one; a store without it
    /// keeps each browser tab as a WebKit preview page.
    private let browserClient: @MainActor () -> BrowserHostClient?

    init(repository: any TaskWorkspaceRepository = InMemoryTaskWorkspaceRepository(),
         browserClient: @escaping @MainActor () -> BrowserHostClient? = { nil }) {
        self.repository = repository
        self.browserClient = browserClient
        let saved = repository.loadSizes()
        sizes = TaskWorkspaceSizeStore(saved ?? .init())
        sizesKnown = saved != nil
        sizes.onChange = { [weak self] in self?.sizesChanged() }
    }

    /// The task's workspace if it is loaded, without loading it (which would set its panels before the window does).
    func loadedState(for id: UUID) -> TaskWorkspaceState? {
        states[id]
    }

    func state(for id: UUID, initialSurface: String? = nil) -> TaskWorkspaceState {
        if let state = states[id] { return state }
        let loaded = repository.load(for: id)
        let saved = loaded?.migrated
        if !sizesKnown, let saved {
            let carried = TaskWorkspaceSizes(carriedBy: saved.layout).clamped
            if carried != TaskWorkspaceSizes() { sizes.update { $0 = carried } }
        }
        let state = TaskWorkspaceState(snapshot: saved ?? .init(
            panels: TaskSurfaceNavigationProjection.initialPanelState(surfaceID: initialSurface)
        ), sizes: sizes)
        if saved == nil, initialSurface != nil { state.terminalStartRequested = state.panels.isTerminalPresented }
        state.onChange = { [weak self] in self?.changed(id) }
        state.onSideChatClose = { [weak self] in self?.onSideChatClose?(id) }
        states[id] = state
        if let client = browserClient() { state.attachBrowser(client, session: id) }
        // A snapshot moved to newer panel rules is saved under them at once: its new browser tab keys
        // must be the same the next time Yardlet starts.
        if let loaded, loaded != saved { changed(id) }
        return state
    }

    /// The new-task screen's panels, kept as a task's are under an identity of their own (the Codex
    /// app keeps a draft's tabs under the draft's thread id), and taken over by the task it starts.
    static let draftID = UUID(uuidString: "6E657754-6173-4B00-8000-000000000001")!

    var draft: TaskWorkspaceState { state(for: Self.draftID) }

    /// The task started from the new-task screen takes over its panels and its terminal's shell.
    func handOffDraft(to taskID: UUID) {
        guard taskID != Self.draftID else { return }
        state(for: taskID).takeOver(from: draft, taskID: taskID)
    }

    func rememberSelection(_ id: UUID?) {
        repository.saveSelection(id.map(TaskWorkspaceSelection.task) ?? .home)
    }

    func restoreSelection(in store: SessionStore) {
        switch repository.loadSelection() {
        case .home: store.selectedSessionID = nil
        case .task(let id) where store.sessions.contains(where: { $0.id == id }): store.selectedSessionID = id
        default: break
        }
    }

    func remove(for id: UUID) {
        if let state = states.removeValue(forKey: id) {
            state.onChange = nil
            state.endTerminal()
            state.detachBrowser()
            state.browserTabs.terminateForApplicationShutdown()
        }
        dirtyIDs.remove(id)
        repository.remove(for: id)
    }

    func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        for id in dirtyIDs {
            if let state = states[id] { repository.save(state.snapshot, for: id) }
        }
        dirtyIDs.removeAll()
        if sizesDirty {
            repository.saveSizes(sizes.sizes)
            sizesDirty = false
        }
    }

    private func changed(_ id: UUID) {
        dirtyIDs.insert(id)
        scheduleSave()
    }

    private func sizesChanged() {
        sizesKnown = true
        sizesDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persistNow()
        }
    }
}

/// What the side panel shows over its tabs when the session rail opens an agent or a background task,
/// as the Codex app opens a subagent's conversation and a background terminal's output as side-panel
/// tabs and the Claude app opens them in its Background tasks pane. A Claude Code subagent keeps its
/// own subtask panel. Not a tab, and not saved: closing it returns to the tab it covered.
enum TaskPanelDetail: Equatable, Sendable {
    /// A `run_agent` subagent's conversation.
    case agentRun(UUID, title: String)
    /// A Codex child thread, read from the thread.
    case codexThread(String, title: String)
    /// A Claude Code background task's output, by its activity.
    case claudeTaskOutput(activityID: String, title: String)
    /// A Codex background terminal's output, by the command item that started it.
    case codexTerminal(processID: String, itemID: String, title: String)

    static let surfaceID = "detail"

    var title: String {
        switch self {
        case let .agentRun(_, title), let .codexThread(_, title), let .claudeTaskOutput(_, title),
             let .codexTerminal(_, _, title): title
        }
    }
}
