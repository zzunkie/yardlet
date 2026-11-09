import SwiftUI

/// The mailbox's thread with its own browser panel beside it, where a link chosen in a message and Open in Gmail or
/// Outlook open (`AppModel.openMailLink`), as a task's side panel sits beside its conversation: the same tab strip,
/// browser pane and widths. The panel holds browser tabs only, its + opens another, and closing it closes its pages.
/// It belongs to no task (`TaskWorkspaceStore.mailID`; docs/MAILBOX.md, "Links").
struct MailWorkspace: View {
    let center: MailboxCenter
    @Bindable var window: MailWindowState
    let actions: MailActions
    /// The panel's tabs; nil once the mailbox is turned off, while the window leaves it.
    let panel: TaskWorkspaceState?

    var body: some View {
        if let panel {
            MailBrowserLayout(panel: panel) { MailContent(center: center, window: window, actions: actions) }
        } else {
            MailContent(center: center, window: window, actions: actions)
        }
    }
}

private struct MailBrowserLayout<Thread: View>: View {
    @Bindable var panel: TaskWorkspaceState
    @ViewBuilder let thread: () -> Thread

    private typealias Navigation = TaskSurfaceNavigationProjection

    /// Pages are not files: the pane's folder is the home folder, as the new-task screen's before it has one.
    private var folder: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        TaskWorkspaceLayout(
            showsTrailing: panel.panels.trailingSurfaceID != nil,
            showsTerminal: false,
            preferences: $panel.layout,
            onReturnToChat: closePanel,
            onCloseTrailing: closePanel,
            chat: thread,
            rail: { EmptyView() },
            trailing: { trailing.environment(\.workSurfaceNavigation, navigation) },
            bottom: { EmptyView() }
        )
    }

    @ViewBuilder
    private var trailing: some View {
        if let key = Navigation.browserKey(inTab: panel.panels.trailingSurfaceID) {
            if let client = panel.browserClient {
                BrowserHostPane(session: TaskWorkspaceStore.mailID, key: key, workspace: panel, client: client,
                                workspaceURL: folder, onNewTab: openNewTab,
                                onCloseTab: { closeTabs([Navigation.browserTabID($0)]) },
                                onShowTab: { showTab(Navigation.browserTabID($0)) })
                    .id(ObjectIdentifier(panel.browserTabs))
            } else {
                BrowserPane(workspaceURL: folder, model: panel.browserTabs.preview(for: key),
                            onClose: { closeTabs([Navigation.browserTabID(key)]) })
                    .id(key)
            }
        }
    }

    private var navigation: WorkSurfaceNavigation {
        WorkSurfaceNavigation(
            tabs: panel.panels.trailingTabs.compactMap { id in
                Navigation.browserKey(inTab: id).map { TaskSidePanelTabs.browserTab($0, in: panel.browserTabs) }
            },
            activeID: panel.panels.trailingSurfaceID,
            choices: [],
            select: { id in showTab(id) },
            open: { _ in openNewTab() },
            closeTab: { id in closeTabs([id]) },
            closeTabs: { ids in closeTabs(ids) },
            closePanel: closePanel,
            kind: .sidePanel,
            browserMenu: .make(for: panel),
            newTab: WorkSurfaceNewTab(help: L10n.string("New tab"), action: openNewTab)
        )
    }

    private func openNewTab() {
        guard panel.openBrowserTab() != nil else { return NSSound.beep() }
        panel.keyboardFocus.move(to: .browser)
    }

    private func showTab(_ id: String) {
        panel.setPanels(Navigation.showing(id, in: panel.panels))
        panel.keyboardFocus.move(to: .browser)
    }

    private func closeTabs(_ ids: [String]) {
        panel.closeSidePanelTabs(ids)
    }

    /// Closing the panel closes its pages: it has no button that shows it again, so nothing stays open unseen.
    private func closePanel() {
        panel.closeSidePanelTabs(panel.panels.trailingTabs)
    }
}
