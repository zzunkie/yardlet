import AppKit
import SwiftUI

/// A row of the sidebar's Cloud section (`SidebarCloudItem`), drawn as a task row is: Codex's mark in
/// the gutter, the title where task titles start, and a running or failed task's state at the end.
/// Clicking a Codex Cloud task opens its page in the default browser, where the Codex CLI sends a
/// cloud task; clicking a dot's task shows the dot and opens the task in its reader. Neither is a task
/// Yardlet shows in the window, so the row is never the selected row and the arrow keys pass it by.
struct SidebarCloudTaskRow: View, @MainActor Equatable {
    let item: SidebarCloudItem
    let onOpen: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    /// The list draws a row again only when its item changed, as it does a task's row.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item }

    /// The row's help and its accessibility value: where the task comes from, its state and its place.
    private var details: String {
        ([item.source, item.stateName, item.detail] as [String?]).compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.sidebarCloudRow)
#endif
        Button(action: onOpen) {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    HarnessIdentityIcon(harness: .codex, size: SidebarMetrics.nestedIconSize * interfaceScale)
                }
                Text(item.title)
                    .font(.system(size: 13 * interfaceScale))
                    .lineLimit(1)
                Spacer(minLength: 3)
                SidebarRowTrailingItemsView(items: SidebarTaskIndicatorProjection.trailingItems(status: item.status))
            }
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.rowHeight * interfaceScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
        .onRestingHover { isHovering = $0 }
        .help(details)
        .accessibilityLabel("\(item.title), Codex")
        .accessibilityValue(details)
        .contextMenu {
            if let url = item.url {
                Button(L10n.string("Open in default browser"), action: onOpen)
                Button(L10n.string("Copy link")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }
}
