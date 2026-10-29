import SwiftUI

/// A new browser tab's start page, as Safari's and Chrome's, and the Codex app's New tab page over its blank browser
/// tab (docs/BROWSER_HOST.md, section 3, "Start page"): Yardlet draws it over the tab's blank page, so the agent's
/// browser tools read nothing of it, and the address field keeps the keyboard. It offers the pages this task's tabs
/// showed (`TaskBrowserTabs.suggestedPages`) and the sites visited most (`BrowserAddressHistory.topSites`); one chosen
/// opens in this tab. With neither, it says to enter an address.
struct BrowserStartPage: View {
    struct Site: Identifiable, Equatable {
        let address: String
        let title: String
        var icon: Data?
        var id: String { address }
    }

    /// The task's pages, each by its address (`TaskSidePanelTabs.visitedPageTabs`).
    let pages: [WorkSurfaceTab]
    let sites: [Site]
    let onOpen: (String) -> Void
    let onRemovePage: (String) -> Void
    let onRemoveSite: (String) -> Void

    static let pageCount = 6
    /// Chrome's new tab shows eight sites, four to a row.
    static let siteCount = 8

    var body: some View {
        if pages.isEmpty && sites.isEmpty {
            Self.empty
        } else {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !pages.isEmpty {
                            LauncherPageSection(pages: pages, onOpen: onOpen, onRemove: onRemovePage)
                        }
                        if !sites.isEmpty { siteSection }
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 28)
                    // Centred while it fits, as the side panel's launcher is; it scrolls when it does not.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
            .background(ParityTheme.canvas)
        }
    }

    private var siteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Frequently visited"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 72), spacing: 4), count: 4), spacing: 4) {
                ForEach(sites) { site in
                    BrowserStartPageSiteTile(site: site) { onOpen(site.address) }
                        .contextMenu {
                            Button(L10n.string("Remove from history")) { onRemoveSite(site.address) }
                        }
                }
            }
        }
    }

    /// A tab with no page and nothing to offer, as the Codex app's "Start browsing".
    static var empty: some View {
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
}

/// One of the sites visited most: its icon, or its first letter before a tab shows the site, over its page's title,
/// as Chrome's and the Codex app's tiles.
private struct BrowserStartPageSiteTile: View {
    let site: BrowserStartPage.Site
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(ParityTheme.subtleFill)
                    if let icon = site.icon, let image = BrowserFaviconImage.image(icon) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text(Self.initial(of: site.address))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                Text(site.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(isHovering ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(site.address)
        .accessibilityLabel(site.title)
        .accessibilityValue(site.address)
    }

    /// The site's first letter, `www.` aside.
    static func initial(of address: String) -> String {
        let site = BrowserAddressHistory.site(of: address) ?? address
        return site.first.map { String($0).uppercased() } ?? "?"
    }
}
