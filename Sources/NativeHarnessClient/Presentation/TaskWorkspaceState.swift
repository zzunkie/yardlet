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
    var sideChatSessionID: UUID?
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
    var sideChatSessionID: UUID? { didSet { if sideChatSessionID != oldValue { onChange?() } } }
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
    /// The terminal's shell, kept here rather than by the terminal panel, so it goes on while the task
    /// is off screen or its panel hidden, and a shell the new-task screen opened goes on in the task it
    /// starts. Never saved.
    @ObservationIgnored private var terminalSession: NativeTerminalSession?
    /// Changes when the shell the terminal panel shows is replaced rather than ended by the panel: a
    /// restart in the task's folder, or a task taking over the new-task screen's.
    private(set) var terminalRevision = 0
    /// A command a conversation card handed to the task's terminal, until the terminal has typed
    /// it. Closing the terminal or leaving the task drops it. Never persisted.
    var terminalHandoff: TerminalCommandRequest?
    @ObservationIgnored var onChange: (() -> Void)?

    /// - Parameter sizes: the window's shared sizes; a task shown on its own (a render, a test)
    ///   keeps the sizes its snapshot carries.
    init(snapshot: TaskWorkspaceSnapshot = .init(), sizes: TaskWorkspaceSizeStore? = nil) {
        panels = snapshot.panels
        self.sizes = sizes ?? TaskWorkspaceSizeStore(TaskWorkspaceSizes(carriedBy: snapshot.layout))
        isExpanded = snapshot.layout.isExpanded
        review = snapshot.review ?? .init()
        sideChatSessionID = snapshot.sideChatSessionID
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

    /// The shell the terminal panel shows: the one kept, else a new one in `folder` that starts when a
    /// panel shows it. One that exited and no panel showed any more has ended
    /// (`NativeTerminalSession.panelDisappeared`).
    func terminal(in folder: URL, launch: ShellLaunchEnvironment, taskID: UUID?) -> NativeTerminalSession {
        if let terminalSession, !terminalSession.hasEnded { return terminalSession }
        let session = NativeTerminalSession(workspaceURL: folder, launch: launch, taskID: taskID)
        terminalSession = session
        return session
    }

    /// "Restart in …": the shell ends and the panel opens the next one in the task's folder.
    func restartTerminal() {
        terminalSession?.end()
        terminalSession = nil
        terminalStartRequested = true
        terminalRevision += 1
    }

    /// The task is archived or deleted: its shell ends with it, as the Codex app closes a thread's
    /// terminals when the thread is archived or deleted.
    func endTerminal() {
        terminalSession?.end()
        terminalSession = nil
    }

    /// A task started from the new-task screen takes over its panels: their tabs, the Files and
    /// browser state, and the terminal's shell, which goes on as it was (the Codex app's thread takes
    /// over its draft's tabs). The new-task screen starts over empty, as the Codex app's does with a
    /// new draft. The browser engine's tabs move separately (`AppModel.handOffDraftWorkspace`).
    func takeOver(from draft: TaskWorkspaceState, taskID: UUID) {
        let startRequested = draft.terminalStartRequested
        setPanels(draft.panels)
        terminalStartRequested = startRequested
        isExpanded = draft.isExpanded

        let files = draft.files
        let browserTabs = draft.browserTabs
        draft.replace(files: WorkspaceFilesState(), browserTabs: TaskBrowserTabs())
        replace(files: files, browserTabs: browserTabs)

        if let shell = draft.terminalSession, !shell.hasEnded {
            terminalSession?.end()
            shell.move(toTask: taskID)
            terminalSession = shell
        }
        draft.terminalSession = nil
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
                                     sideChatSessionID: sideChatSessionID,
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
        panels = value
        onChange?()
        // The browser tab the panel shows is the one in front, which the agent's tools use when they
        // name no tab; the browser is told before anything else can ask it.
        frontShownBrowserTab()
    }

    /// "Run in terminal" on a command card (plan B10): the task's terminal runs `command` as the
    /// terminal's own handoff always has, typed with Return. The click is the explicit gesture that
    /// may start a shell; the caller opens the terminal panel.
    func handOffToTerminal(_ command: String) {
        terminalHandoff = TerminalCommandRequest(command: command)
        terminalStartRequested = true
    }

    /// The terminal is done with a handoff, typed or not.
    func finishTerminalHandoff(_ id: TerminalCommandRequest.ID) {
        if terminalHandoff?.id == id { terminalHandoff = nil }
    }

    /// Leaving the task leaves its terminal's shell running; nothing waits to be typed or started in it
    /// on the next visit.
    func leaveTerminal() {
        terminalStartRequested = false
        terminalHandoff = nil
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
