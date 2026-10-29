import AppKit
import SwiftUI

/// What a browser tab is called on its side-panel tab, as the Codex app names it (`Iee`): the page's
/// title, else its host, else "New tab".
enum BrowserTabTitle {
    static func make(pageTitle: String, address: String?) -> String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chromium names a blank tab by its address, as it names any page without a title.
        if !trimmed.isEmpty, trimmed != "about:blank" { return trimmed }
        if let address, address != "about:blank", !address.isEmpty {
            return URL(string: address)?.host() ?? address
        }
        return L10n.string("New tab")
    }
}

/// Page icons as images, made once per icon.
@MainActor
enum BrowserFaviconImage {
    private static let cache = NSCache<NSData, NSImage>()

    static func image(_ png: Data) -> NSImage? {
        if let image = cache.object(forKey: png as NSData) { return image }
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: png as NSData)
        return image
    }
}

/// A browser tab's own items in its side-panel tab's menu, as the Codex app's browser tab menu has
/// them (`thread.sidePanel.browserTabMenu`): New Tab to the Right, Reload, Duplicate, Copy URL and Open
/// in External Browser. The Codex app's Rename, Mute and Fork are not offered.
struct BrowserTabMenuActions: Sendable {
    /// The page the tab shows, or showed before Yardlet restarted.
    var address: @MainActor @Sendable (UUID) -> String?
    /// The browser has the tab open, so it can reload.
    var isOpen: @MainActor @Sendable (UUID) -> Bool
    var newTabToTheRight: @MainActor @Sendable (UUID) -> Void
    var reload: @MainActor @Sendable (UUID) -> Void
    var duplicate: @MainActor @Sendable (UUID) -> Void

    /// The items for the browser tabs of `workspace`'s side panel. A task with no room for another tab
    /// beeps, as a menu item that cannot act does.
    @MainActor
    static func make(for workspace: TaskWorkspaceState) -> Self {
        BrowserTabMenuActions(
            address: { [weak workspace] key in workspace?.browserTabAddress(key) },
            isOpen: { [weak workspace] key in
                guard let workspace else { return false }
                // Without the engine, each tab's WebKit page reloads itself.
                return workspace.browserClient == nil || workspace.isBrowserTabOpen(key)
            },
            newTabToTheRight: { [weak workspace] key in
                if workspace?.openBrowserTab(after: TaskSurfaceNavigationProjection.browserTabID(key)) == nil { NSSound.beep() }
            },
            reload: { [weak workspace] key in
                guard let workspace else { return }
                if workspace.browserClient == nil { workspace.browserTabs.preview(for: key).reload() }
                else { workspace.reloadBrowserTab(key) }
            },
            duplicate: { [weak workspace] key in
                if workspace?.duplicateBrowserTab(key) == nil { NSSound.beep() }
            })
    }

    /// Copy URL is offered for a page, as the Codex app offers it (`sxo`: a web address, not a blank tab).
    static func copiableAddress(_ address: String?) -> String? {
        guard let address, !address.isEmpty, !address.hasPrefix("about:blank"), URL(string: address) != nil else { return nil }
        return address
    }

    /// Open in External Browser is offered for a web page.
    static func externalURL(_ address: String?) -> URL? {
        guard let address, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

/// A side-panel tab's menu, the same for every tab as in the Codex app: a browser tab's own items
/// first, then Close Tab, Close Other Tabs and Close Tabs to the Right.
struct WorkSurfaceTabMenu: View {
    let tabID: String
    let navigation: WorkSurfaceNavigation

    private typealias Navigation = TaskSurfaceNavigationProjection

    var body: some View {
        if let key = Navigation.browserKey(inTab: tabID), let browser = navigation.browserMenu {
            let address = browser.address(key)
            Button(L10n.string("New Tab to the Right")) { browser.newTabToTheRight(key) }
            Button(L10n.string("Reload")) { browser.reload(key) }
                .disabled(!browser.isOpen(key))
            Button(L10n.string("Duplicate")) { browser.duplicate(key) }
            if let copied = BrowserTabMenuActions.copiableAddress(address) {
                Button(L10n.string("Copy URL")) { TranscriptClipboard.copy(copied) }
            }
            if let url = BrowserTabMenuActions.externalURL(address) {
                Button(L10n.string("Open in External Browser")) { OutsideBrowser.open(url) }
            }
            Divider()
        }
        let ids = navigation.tabs.map(\.id)
        let index = ids.firstIndex(of: tabID)
        Button(L10n.string("Close Tab")) { navigation.closeTab(tabID) }
        Button(L10n.string("Close Other Tabs")) { navigation.closeTabs(ids.filter { $0 != tabID }) }
            .disabled(!ids.contains { $0 != tabID })
        Button(L10n.string("Close Tabs to the Right")) {
            if let index { navigation.closeTabs(Array(ids[(index + 1)...])) }
        }
        .disabled(index.map { $0 + 1 >= ids.count } ?? true)
    }
}
