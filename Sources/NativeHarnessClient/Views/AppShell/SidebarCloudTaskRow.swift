import AppKit
import SwiftUI

/// A Codex Cloud task in the sidebar's Cloud section, drawn as a task row is: Codex's mark in the
/// gutter, the title where task titles start, and a running or failed task's state at the end.
/// Clicking it opens the task's page in the default browser, where the Codex CLI sends a cloud task;
/// it is not a task Yardlet shows, so it is never the selected row and the arrow keys pass it by.
struct SidebarCloudTaskRow: View, @MainActor Equatable {
    let task: CodexCloudTask
    let onOpen: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    /// The list draws a row again only when its task changed, as it does a task's row.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.task == rhs.task }

    /// The marks task rows use: Codex's running task is "Running", a failed one the error mark.
    private var status: SidebarTaskStatus? {
        switch task.status {
        case .pending: .running
        case .error: .failed(message: nil)
        case .ready, .applied, nil: nil
        }
    }

    private var stateName: String? {
        switch task.status {
        case .pending, .error: status?.accessibilityName
        case .ready: L10n.string("Ready")
        case .applied: L10n.string("Applied")
        case nil: nil
        }
    }

    /// The row's help and its accessibility value: where it runs, its state and its environment.
    private var details: String {
        ([L10n.string("Codex Cloud"), stateName, task.environment] as [String?]).compactMap(\.self)
            .joined(separator: " · ")
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
                Text(task.title)
                    .font(.system(size: 13 * interfaceScale))
                    .lineLimit(1)
                Spacer(minLength: 3)
                SidebarRowTrailingItemsView(items: SidebarTaskIndicatorProjection.trailingItems(status: status))
            }
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.rowHeight * interfaceScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
        .onHover { isHovering = $0 }
        .help(details)
        .accessibilityLabel("\(task.title), Codex")
        .accessibilityValue(details)
        .contextMenu {
            Button(L10n.string("Open in default browser"), action: onOpen)
            Button(L10n.string("Copy link")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(task.url.absoluteString, forType: .string)
            }
        }
    }
}
