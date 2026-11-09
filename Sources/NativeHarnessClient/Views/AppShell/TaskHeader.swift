import AppKit
import SwiftUI

/// What a task's header offers besides its panel buttons. The window draws one header for each task
/// it shows: the title bar is the header of the task or the new-task screen the tab shows, and in a
/// split view each pane's header is its task's header, as the Claude app gives each split pane its own
/// header (`paneIndex`); there the title bar is only the window's tabs, when it has two or more.
struct TaskHeaderActions {
    var canManageTask = true
    var managesWorkspace = true
    var accountName: ((SessionRecord) -> String?)? = nil
    var hasOriginalConversation: ((SessionRecord) -> Bool)? = nil
    var hasProviderSession: ((SessionRecord) -> Bool)? = nil
    var isAttached: (SessionRecord) -> Bool = { _ in false }
    var onResume: (SessionRecord) -> Void = { _ in }
    var onRename: (SessionRecord) -> Void = { _ in }
    /// "Rename from Recent Conversation"; nil leaves the item out (`TaskSidebar.onRenameFromConversation`).
    var onRenameFromConversation: ((SessionRecord) -> Void)? = nil
    var onTogglePinned: (SessionRecord) -> Void = { _ in }
    var onArchive: (SessionRecord) -> Void = { _ in }
    var onBackToConversation: (SessionRecord) -> Void = { _ in }
    /// The project a task is listed under, by its project ID first, so a moved task names its new one.
    var projectName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
    /// The projects a task can move to and whether it can go back to Chats (`TaskProjectMove`).
    var projectMoveOptions: (SessionRecord) -> TaskProjectMove.Options = { _ in .none }
    var onMoveToProject: (SessionRecord, Project?) -> Void = { _, _ in }
    var onChooseAccount: ((SessionRecord) -> Void)? = nil
    var canOpenOriginalConversation: (SessionRecord) -> Bool = { _ in false }
    var onOpenOriginalConversation: ((SessionRecord) -> Void)? = nil
    /// The pull request the task made (`TaskPullRequestMonitor`), shown beside the harness.
    var pullRequest: (SessionRecord) -> TaskPullRequest? = { _ in nil }
    var onOpenPullRequest: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The ports the task's processes listen on (`TaskResourceMonitor.servers(of:)`), after its pull
    /// request; read in the header's body, so a server starting redraws only that header.
    var servers: (SessionRecord) -> [TaskServerPort] = { _ in [] }
    /// Opens a server in the task's browser.
    var onOpenServer: (SessionRecord, TaskServerPort) -> Void = { _, _ in }
}

/// A task's title, which opens the task's actions, its harness, its pull request and its state.
struct TaskHeaderIdentity: View {
    let session: SessionRecord
    let actions: TaskHeaderActions
    /// A split pane's header, smaller than the title bar's.
    var compact = false
    /// The harness's name beside its mark; a header short of room leaves it to the title.
    var showsHarnessName = true
    /// The header's empty part moves the window, so the pane drags by its harness (`SplitPaneHeader`).
    var dragsByHarness = false

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            // The title is offered its width before the status's servers (`TaskServersLink`), and the status
            // keeps the room its harness and pull request need, as before.
            TaskTitleMenu(session: session, actions: actions, size: compact ? 12 : 13)
                .layoutPriority(1)
            TaskHeaderStatus(session: session, actions: actions, compact: compact, showsHarnessName: showsHarnessName,
                             dragsByHarness: dragsByHarness)
        }
    }
}

/// The task's title, which opens its actions: in its header, and in the window tab that shows it. The
/// title takes its own width, so the header's empty part beside it stays free (the window's title bar
/// moves the window there; a split pane's header moves the pane, or the window at the window's top).
struct TaskTitleMenu: View {
    let session: SessionRecord
    let actions: TaskHeaderActions
    var size: CGFloat = 13

    @FocusState private var taskInfoFocused: Bool

    var body: some View {
        Menu { menuContents } label: {
            Text(session.title)
                .font(.system(size: size, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.primary)
        .parityPointer()
        .focused($taskInfoFocused)
        .taskFocus(.taskActions, isFocused: $taskInfoFocused)
        .accessibilityLabel(L10n.string("Task actions"))
        .accessibilityValue([session.title, actions.projectName(session),
                             session.status.displayName].joined(separator: ", "))
        .help(actions.managesWorkspace ? "\(session.title)\n\(session.workspaceURL.path(percentEncoded: false))" : session.title)
    }

    @ViewBuilder var menuContents: some View {
        if let name = actions.accountName?(session) ?? session.connection?.name {
            Text(L10n.format("Account: %@", name))
        }
        if TaskAccountSwitch.supports(session.harness), let onChooseAccount = actions.onChooseAccount {
            Button(L10n.string("Choose account…")) { onChooseAccount(session) }
            Divider()
        }
        Button(L10n.string("Rename task")) { actions.onRename(session) }.disabled(!actions.canManageTask)
        if let onRenameFromConversation = actions.onRenameFromConversation {
            RenameFromConversationMenuItem(session: session, isDisabled: !actions.canManageTask,
                                           action: onRenameFromConversation)
        }
        Button(L10n.string(session.isPinned ? "Unpin" : "Pin")) { actions.onTogglePinned(session) }
        TaskProjectMoveMenuItems(options: actions.projectMoveOptions(session)) { actions.onMoveToProject(session, $0) }
            .disabled(!actions.canManageTask)
        Button(L10n.string("Archive")) { actions.onArchive(session) }
        if actions.hasOriginalConversation?(session) ?? (session.harness == .claudeCode && session.inheritedContext?.nativeConversationOrigin != nil),
           let onOpenOriginalConversation = actions.onOpenOriginalConversation {
            OriginalConversationMenuItem(canOpen: actions.canOpenOriginalConversation(session),
                onOpen: { onOpenOriginalConversation(session) })
        }
        Divider()
        Button(L10n.string("Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([session.workspaceURL])
        }.disabled(!actions.managesWorkspace)
        Button(L10n.string("Back to conversation")) {
            actions.onBackToConversation(session)
        }
        if actions.canManageTask && !actions.isAttached(session) && session.status != .running && session.status != .waitingForApproval {
            Divider()
            Button(L10n.string((actions.hasProviderSession?(session) ?? (session.providerSessionID != nil)) ? "Resume" : "Retry")) {
                actions.onResume(session)
            }
        }

    }

}

/// What a task's header shows after its title: its harness, its pull request and its state. In the
/// title bar with the window's tabs, the shown tab carries the harness's mark and this sits beside the
/// task's buttons.
struct TaskHeaderStatus: View {
    let session: SessionRecord
    let actions: TaskHeaderActions
    var compact = false
    var showsHarness = true
    var showsHarnessName = true
    var dragsByHarness = false
    @AppStorage(TaskServersPreference.key) private var showsServers = true

    var body: some View {
        let servers = showsServers ? actions.servers(session) : []
        if servers.isEmpty {
            row(servers: servers, extent: .none)
        } else {
            // The status takes the room the title leaves (`TaskHeaderIdentity`): in a narrow header the
            // servers' list goes first, then the address, and the harness and pull request stay.
            ViewThatFits(in: .horizontal) {
                row(servers: servers, extent: .all)
                row(servers: servers, extent: .first)
                row(servers: servers, extent: .none)
            }
        }
    }

    private func row(servers: [TaskServerPort], extent: TaskServersLink.Extent) -> some View {
        HStack(spacing: compact ? 7 : 9) {
            if showsHarness {
                HarnessIdentityLabel(harness: session.harness, size: compact ? 13 : 14, showsName: showsHarnessName)
                    .font(.system(size: compact ? 11 : 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .overlay { if dragsByHarness { TabDragHandle().help(session.harness.displayName) } }
            }
            if let pullRequest = actions.pullRequest(session) {
                TaskPullRequestBadgeView(badge: TaskPullRequestBadge(pullRequest), onOpen: actions.onOpenPullRequest)
            }
            if extent != .none {
                TaskServersLink(servers: servers, listsOthers: extent == .all, compact: compact) {
                    actions.onOpenServer(session, $0)
                }
            }
            TaskHeaderActivity(status: session.status)
        }
    }
}

/// The servers a task's processes run, after its pull request, as plain text: "localhost:3000",
/// which opens it in the task's browser (the Claude app names its preview's server "localhost:3000"
/// the same way). With more than one, "and 1 more" beside it lists them all, each with the process
/// listening. Nothing shows without one, or with Settings › General's "Show servers tasks start" off.
struct TaskServersLink: View {
    /// All of them (the first and the list), the first alone, or none, by the header's room.
    enum Extent { case all, first, none }

    let servers: [TaskServerPort]
    var listsOthers = true
    var compact = false
    let onOpen: (TaskServerPort) -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var isHovered = false

    var body: some View {
        if let first = servers.first {
            links(first)
        }
    }

    private func links(_ first: TaskServerPort) -> some View {
        HStack(spacing: 6) {
            Button { onOpen(first) } label: { label(first) }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .parityPointer()
                .help(help)
                .accessibilityLabel(L10n.format("Open %@ in this task's browser", first.address))
                .accessibilityAddTraits(.isLink)
            if listsOthers, servers.count > 1 {
                Menu {
                    ForEach(servers, id: \.port) { server in
                        Button(Self.line(server)) { onOpen(server) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.format("and %lld more", servers.count - 1))
                            .font(.system(size: (compact ? 11 : 11.5) * interfaceScale))
                        Image(systemName: "chevron.down")
                            .font(.system(size: (compact ? 8 : 8.5) * interfaceScale, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                // SwiftUI draws the label, so it reads as the address beside it.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .parityPointer()
                .help(help)
                .accessibilityLabel(L10n.string("This task's servers"))
            }
        }
        .fixedSize()
    }

    private func label(_ first: TaskServerPort) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: (compact ? 10 : 10.5) * interfaceScale))
            Text(first.address)
                .font(.system(size: (compact ? 11 : 11.5) * interfaceScale))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(isHovered ? .primary : .secondary)
        .contentShape(Rectangle())
    }

    /// Each server and the process listening on it, then what pressing does.
    private var help: String {
        let lines = servers.map { "\(Self.line($0)) (PID \($0.processID))" }
        return (lines + [L10n.string("Opens in this task's browser")]).joined(separator: "\n")
    }

    /// "localhost:3000 · node", or the address alone when the process's name could not be read.
    static func line(_ server: TaskServerPort) -> String {
        server.processName.isEmpty ? server.address : "\(server.address) · \(server.processName)"
    }
}

/// Running, waiting for approval, or failed, beside the task's harness.
struct TaskHeaderActivity: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
                .accessibilityLabel(status.displayName)
                .help(status.displayName)
        case .waitingForApproval, .failed:
            Image(systemName: status == .failed ? "exclamationmark.circle" : "exclamationmark.shield")
                .font(.system(size: 12))
                .foregroundStyle(status == .failed ? Color.red : Color.orange)
                .accessibilityLabel(status.displayName)
                .help(status.displayName)
        case .ready, .completed:
            EmptyView()
        }
    }
}

/// Where a header's panel buttons go: beside the title while the header has room for both, otherwise
/// into a "More" menu, as the Claude app folds a narrow header's pane buttons and rail toggle into its
/// overflow menu (`hiddenCount`, `railToggleFolded`).
enum TaskHeaderFold {
    /// The header's width below which the buttons fold: room for a short title, the harness, the
    /// four buttons, and in a pane the close button.
    static func folds(headerWidth: CGFloat, interfaceScale: CGFloat = 1) -> Bool {
        headerWidth < 362 * interfaceScale
    }

    /// The part of that width for a short title and the harness.
    static let titleRoom: CGFloat = 180
}

/// A split view's name in the window tab that shows it, which opens its sidebar row's actions. A split
/// view has no header of its own: each pane's header heads its task.
struct SplitViewTitleMenu: View {
    let title: String
    let isPinned: Bool
    var rename: () -> Void = {}
    var togglePinned: () -> Void = {}
    var dissolve: () -> Void = {}
    var archive: () -> Void = {}

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Menu {
            Button(L10n.string("Rename split view…"), action: rename)
            Button(L10n.string(isPinned ? "Unpin split view" : "Pin split view"), action: togglePinned)
            Button(L10n.string("End split view"), action: dissolve)
            Divider()
            Button(L10n.string("Archive tasks…"), role: .destructive, action: archive)
        } label: {
            Text(title)
                .font(.system(size: 12.5 * interfaceScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
        .parityPointer()
        .accessibilityLabel(L10n.format("Split view: %@", title))
        .help(title)
    }
}

/// A split pane's header: its task's header (title, harness, state, the panel buttons that act on
/// this pane's task) and Close pane, or for an empty pane what fills it. Pressing it focuses the pane.
///
/// With no tab bar over the split view, the panes reach the window's top and the top ones stand in for
/// the title bar, so they read as windows side by side: such a header has the title bar's height and
/// lines up with the sidebar's row, and its empty part moves the window as a title bar's does. The
/// pane then drags by its harness beside its title, as the shown tab drags by its mark.
struct SplitPaneHeader<Identity: View, Controls: View>: View {
    static var height: CGFloat { SplitLayoutMetrics.paneHeaderHeight }

    let isFocused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    /// The pane's task: dragging the header moves the pane beside another, onto another's middle to swap
    /// the two, or onto the window's tabs to give the task a tab of its own (`WindowDragState`). An empty
    /// pane does not drag.
    var dragged: (task: UUID, preview: WindowDragPreview)? = nil
    /// The header stands at the window's top, with no title bar above it.
    var isAtWindowTop = false
    /// The title bar's part for the window's buttons and the sidebar button
    /// (`TitleBarSidebarPart`), ahead of the top-left pane while the sidebar is hidden.
    var windowLead: AnyView? = nil
    @ViewBuilder let identity: (_ isFolded: Bool) -> Identity
    /// The pane's buttons, folded into a menu when the header is narrow.
    @ViewBuilder let controls: (_ isFolded: Bool) -> Controls

    @State private var width: CGFloat = .infinity
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            if let windowLead {
                windowLead
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
            }
            header
        }
        .frame(height: isAtWindowTop ? ParityTheme.titleBarHeight : Self.height)
    }

    private var header: some View {
        // The close button's room comes out of what the title and the buttons share.
        let isFolded = TaskHeaderFold.folds(headerWidth: width - 24, interfaceScale: interfaceScale)
        return HStack(spacing: 6) {
            identity(isFolded)
                .frame(minWidth: 60, maxWidth: isAtWindowTop ? nil : .infinity, alignment: .leading)
                .layoutPriority(1)
            if isAtWindowTop {
                WindowDragRegion(onPress: onFocus).frame(minWidth: 8, maxWidth: .infinity)
            }
            controls(isFolded)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .foregroundStyle(.secondary)
            .help(L10n.string("Close pane"))
            .accessibilityLabel(L10n.string("Close pane"))
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(isFocused ? ParityTheme.selectedFill : ParityTheme.subtleFill)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .windowDraggable(dragged.map { .pane(sessionID: $0.task) }, preview: dragged?.preview)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth in
            if width != measuredWidth { width = measuredWidth }
        }
    }
}
