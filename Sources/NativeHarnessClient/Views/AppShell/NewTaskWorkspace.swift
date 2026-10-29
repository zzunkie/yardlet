import SwiftUI

/// The new-task screen with the panels a task's screen has: the terminal below it and the side panel
/// beside it (the launcher, the browser, files and other tasks' conversations), in the folder the
/// draft starts in, or the home folder before there is one (the Claude app's New session terminal
/// opens in the chosen folder, else in the home folder). The task the screen starts takes them over,
/// shell and pages as they are (`AppModel.handOffDraftWorkspace`), as the Codex app's thread takes
/// over its draft's tabs.
///
/// Leaving the screen ends its terminal's shell, as leaving a task ends the task's; the side panel's
/// tabs and the browser's pages stay with the draft.
struct NewTaskWorkspace<Home: View>: View {
    let draft: NewTaskDraft
    @Bindable var workspaceState: TaskWorkspaceState
    var focusedSurface: FocusState<TaskSurface?>.Binding
    /// Other tasks' conversations as side-panel tabs.
    var sidePanelTasks: SidePanelTaskServices? = nil
    @ViewBuilder let home: () -> Home
    @Environment(\.terminalShellLaunch) private var terminalShellLaunch

    private typealias Navigation = TaskSurfaceNavigationProjection

    private var panels: Navigation.PanelState { workspaceState.panels }

    /// Where the terminal, the Files panel and a restart in the folder open. Read here, so a folder
    /// chosen on the screen redraws this view and not the window around it.
    private var folder: URL {
        draft.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        TaskWorkspaceLayout(
            showsTrailing: panels.trailingSurfaceID != nil,
            showsTerminal: panels.isTerminalPresented,
            preferences: $workspaceState.layout,
            onReturnToChat: closeSidePanel,
            onCloseTrailing: closeSidePanel,
            onCloseTerminal: closeTerminal,
            chat: home,
            rail: { EmptyView() },
            trailing: { trailing.environment(\.workSurfaceNavigation, navigation) },
            bottom: { terminal }
        )
        .onDisappear { workspaceState.leaveTerminal() }
    }

    @ViewBuilder
    private var trailing: some View {
        let shown = panels.trailingSurfaceID
        if shown == Navigation.launcherID {
            SidePanelLauncher(
                workspaceURL: folder, choices: TaskSidePanelTabs.draftChoices,
                pages: { [workspaceState] in
                    TaskSidePanelTabs.visitedPageTabs(workspaceState.browserTabs,
                                                      icons: workspaceState.browserClient?.addressHistory,
                                                      limit: SidePanelLauncher.pageCount)
                },
                tasks: { [sidePanelTasks] in sidePanelTasks?.choiceTabs() ?? [] },
                onOpen: open, onOpenPage: openPage,
                onRemovePage: { workspaceState.browserTabs.removeVisited($0) },
                onClose: { closeTab(Navigation.launcherID) })
        } else if let shown, let taskID = Navigation.taskID(inTab: shown) {
            // A tab whose task was archived or deleted closes.
            if let sidePanelTasks, let record = sidePanelTasks.record(taskID) {
                sidePanelTasks.tab(record) { closeTab(shown) }
            } else {
                Color.clear.onAppear { closeTab(shown) }
            }
        } else if shown == "files" {
            FilesPane(workspaceURL: folder, state: workspaceState.files, onClose: { closeTab("files") })
                .id(folder)
        } else if let key = Navigation.browserKey(inTab: shown) {
            browser(key)
        } else if let shown {
            // What needs a task (Review, a side chat) is not offered here.
            Color.clear.onAppear { closeTab(shown) }
        }
    }

    /// One of the screen's browser tabs, which the task it starts takes over, pages and all.
    @ViewBuilder
    private func browser(_ key: UUID) -> some View {
        if let client = workspaceState.browserClient {
            BrowserHostPane(session: TaskWorkspaceStore.draftID, key: key, workspace: workspaceState, client: client,
                            workspaceURL: folder, onNewTab: openNewBrowserTab,
                            onCloseTab: { closeTab(Navigation.browserTabID($0)) },
                            onShowTab: { showTab(Navigation.browserTabID($0)) })
                .id(ObjectIdentifier(workspaceState.browserTabs))
        } else {
            BrowserPane(workspaceURL: folder, model: workspaceState.browserTabs.preview(for: key),
                        onClose: { closeTab(Navigation.browserTabID(key)) })
                .id(key)
        }
    }

    /// The launcher's and the + menu's Browser, and ⌘T on a page: a new browser tab.
    private func openNewBrowserTab() {
        guard workspaceState.openBrowserTab() != nil else { return NSSound.beep() }
        workspaceState.keyboardFocus.move(to: .browser)
    }

    /// A page the launcher offers, in a new browser tab.
    private func openPage(_ address: String) {
        guard let url = URL(string: address), workspaceState.openBrowserPage(url) else { return NSSound.beep() }
        workspaceState.keyboardFocus.move(to: .browser)
    }

    private var terminal: some View {
        let _ = workspaceState.terminalRevision
        let session = workspaceState.terminal(in: folder, launch: terminalShellLaunch, taskID: nil)
        return TerminalPane(
            session: session,
            startsAutomatically: workspaceState.terminalStartRequested,
            folder: TerminalFolderContext(folders: [folder], restart: { workspaceState.restartTerminal() }),
            onClose: closeTerminal
        )
        .id(ObjectIdentifier(session))
    }

    private var navigation: WorkSurfaceNavigation {
        let tasks = sidePanelTasks
        let filePath = workspaceState.files.preferences.selectedPath
        return WorkSurfaceNavigation(
            tabs: panels.trailingTabs.compactMap { id in
                if let taskID = Navigation.taskID(inTab: id) {
                    return tasks?.record(taskID).map { TaskSidePanelTabs.taskTab($0) }
                }
                return TaskSidePanelTabs.tab(id, selectedFilePath: filePath, browserTabs: workspaceState.browserTabs)
            },
            activeID: panels.trailingSurfaceID,
            choices: TaskSidePanelTabs.draftChoices,
            taskChoices: { tasks?.choiceTabs(limit: SidePanelTaskServices.menuCount) ?? [] },
            select: { id in showTab(id) },
            open: { id in open(id) },
            closeTab: { id in closeTab(id) },
            closeTabs: { ids in closeTabs(ids) },
            closePanel: closeSidePanel,
            browserMenu: .make(for: workspaceState),
            owner: TaskWorkspaceStore.draftID
        )
    }

    /// A tab in the strip only shows its panel; it never starts a shell.
    private func showTab(_ id: String) {
        workspaceState.setPanels(Navigation.showing(id, in: panels))
        workspaceState.keyboardFocus.move(to: .visibleContent(in: workspaceState.panels))
    }

    private func open(_ id: String) {
        if id == Navigation.browserChoiceID { return openNewBrowserTab() }
        guard id == TaskSurface.terminal.rawValue else { return showTab(id) }
        // The terminal opens below the screen; a launcher it was chosen from has done its job.
        var next = panels
        if next.trailingSurfaceID == Navigation.launcherID {
            next = Navigation.closingTrailingTab(Navigation.launcherID, in: next)
        }
        next.isTerminalPresented = true
        workspaceState.setPanels(next)
        workspaceState.keyboardFocus.move(to: .terminal)
    }

    private func closeTab(_ id: String) {
        closeTabs([id])
    }

    /// Closing a browser tab closes its page; the panel moves to the tab used before, as for any tab.
    private func closeTabs(_ ids: [String]) {
        workspaceState.closeSidePanelTabs(ids)
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .visibleContent(in: workspaceState.panels))
    }

    private func closeSidePanel() {
        workspaceState.setPanels(Navigation.hidingTrailing(panels))
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .visibleContent(in: workspaceState.panels))
    }

    private func closeTerminal() {
        var next = panels
        next.isTerminalPresented = false
        workspaceState.setPanels(next)
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .visibleContent(in: workspaceState.panels))
    }
}
