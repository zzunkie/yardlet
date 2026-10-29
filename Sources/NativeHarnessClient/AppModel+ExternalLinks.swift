import Foundation

/// Links and HTML files other apps open with Yardlet once the person has made it their default web browser
/// (`Packaging/Info.plist` claims http, https and HTML for that; docs/BROWSER_HOST.md, "Default browser"). Each opens in a
/// new browser tab where the person already looks, as Chrome opens an outside link in a new tab of the window used last:
/// the side panel of the task the window shows (its focused pane in a split view), else the new-task screen's. The window
/// keeps the task it shows. A task with no room for another tab, or an empty split pane, which has no side panel, sends
/// the link to the new-task screen in the window's tab for it, as ⌘T opens it; with no room there either the link goes to
/// another browser (`elsewhere`), never back to Yardlet. Links that arrive while launch reads the task index wait for it.
extension AppModel {
    func openExternalLinks(_ urls: [URL], elsewhere: @escaping @MainActor (URL) -> Void) {
        guard !isRestoringIndex else {
            pendingExternalLinks.append((urls, elsewhere))
            return
        }
        for url in urls { openExternalLink(url, elsewhere: elsewhere) }
    }

    /// Links that arrived while launch was reading the task index, opened once it has.
    func handlePendingExternalLinks() {
        let pending = pendingExternalLinks
        pendingExternalLinks = []
        for (urls, elsewhere) in pending { openExternalLinks(urls, elsewhere: elsewhere) }
    }

    /// A page opened in a panel brings the window's tasks back into view, from personal agents or
    /// scheduled tasks, as opening a task from a notification does; a link sent elsewhere leaves it.
    private func openExternalLink(_ url: URL, elsewhere: @MainActor (URL) -> Void) {
        if let task = splits.focusedSessionID, store.sessions.contains(where: { $0.id == task }),
           taskWorkspaces.state(for: task).openBrowserPage(url) {
            taskSurfaceRevealRequest += 1
            return
        }
        guard taskWorkspaces.draft.openBrowserPage(url) else { return elsewhere(url) }
        if splits.selection != .home { splits.newTab() }
        taskSurfaceRevealRequest += 1
    }
}
