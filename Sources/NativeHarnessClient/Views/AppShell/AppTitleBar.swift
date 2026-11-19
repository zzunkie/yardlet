import AppKit
import SwiftUI

/// The title bar's part above the sidebar: the window's buttons' room, the sidebar button and, while the
/// sidebar shows, the activity view and New task. The sidebar's column draws it at its top; without the
/// sidebar it leads the title bar (`IntegratedTitleBar`), which then keeps the window's buttons' room.
struct TitleBarSidebarPart: View {
    let isSidebarVisible: Bool
    let width: CGFloat
    let onToggleSidebar: () -> Void
    let onNewTask: () -> Void
    /// The activity view's button, beside New task while the sidebar shows.
    var activityToggle: ActivityViewToggle? = nil

    /// The part's width without the sidebar.
    static let collapsedWidth: CGFloat = 154

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 66)
            ParityIconButton(
                systemName: "sidebar.left",
                help: isSidebarVisible ? L10n.string("Hide sidebar") : L10n.string("Show sidebar"),
                shortcut: MacShortcut.toggleSidebar.binding,
                action: onToggleSidebar
            )
            WindowDragRegion().frame(minWidth: 4, maxWidth: .infinity)
            if isSidebarVisible, let activityToggle {
                ActivityViewButton(toggle: activityToggle)
            }
            // ⌘N is File › New task (`MacShortcut.newTask.binding`), which does the same.
            ParityIconButton(
                systemName: "square.and.pencil",
                help: L10n.string("New task"),
                shortcut: MacShortcut.newTask.binding,
                action: onNewTask
            )
        }
        .padding(.trailing, 7)
        .frame(width: width, height: ParityTheme.titleBarHeight)
        .background(ParityTheme.sidebar)
        .accessibilitySortPriority(ParityAccessibility.titleBar)
        .focusSection()
    }
}

/// The window's tabs in the title bar, once there are two or more: the tab the window shows holds the
/// shown item's title, which opens its actions, as Safari's compact tab bar puts the page's field in the
/// active tab.
struct TitleBarTabs {
    let tabs: [WindowTab]
    let selection: WindowItem
    let onSelect: (WindowItem) -> Void
    let onClose: (WindowItem) -> Void
    let onCloseOthers: (WindowItem) -> Void
    let onNewTab: () -> Void
    /// A sidebar task dropped on the bar, before a tab or after the last (nil).
    var onOpenTask: (UUID, WindowItem?) -> Void = { _, _ in }
}

/// The title bar beside the sidebar: the header of the item the tab shows, with the window's tabs when it
/// has two or more. For one task it is the task's header (its title, which opens its actions, harness,
/// pull request, state, and the find, rail, terminal and side panel buttons); for a split view the split
/// view's name and actions, its tasks' headers being in their panes; for the new-task screen its panel
/// buttons. A task's area draws it over its conversation (`TaskAreaHeader`), so a side panel beside the
/// conversation reaches the window's top with its tabs in this row.
struct IntegratedTitleBar: View {
    let session: SessionRecord?
    let isSidebarVisible: Bool
    let isAttached: Bool
    /// The session rail is on screen for the task, beside the conversation or raised over it.
    let showsSessionRail: Bool
    let onToggleSessionRail: () -> Void
    /// The window's rail state, read here so the window around the title bar does not follow it.
    var sessionRail: SessionRailWindowState? = nil
    @Binding var panelState: TaskSurfaceNavigationProjection.PanelState
    var focusedSurface: FocusState<TaskSurface?>.Binding
    let onToggleSidebar: () -> Void
    let onNewTask: () -> Void
    let onResume: (SessionRecord) -> Void
    let onRename: (SessionRecord) -> Void
    var onRenameFromConversation: ((SessionRecord) -> Void)? = nil
    let onTogglePinned: (SessionRecord) -> Void
    let onArchive: (SessionRecord) -> Void
    let onBackToConversation: (SessionRecord) -> Void
    /// The project a task is listed under, by its project ID first, so a moved task names its new one.
    var projectName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
    /// The projects a task can move to and whether it can go back to Chats (`TaskProjectMove`).
    var projectMoveOptions: (SessionRecord) -> TaskProjectMove.Options = { _ in .none }
    var onMoveToProject: (SessionRecord, Project?) -> Void = { _, _ in }
    var onChooseAccount: ((SessionRecord) -> Void)? = nil
    var canOpenOriginalConversation: (SessionRecord) -> Bool = { _ in false }
    var onOpenOriginalConversation: ((SessionRecord) -> Void)? = nil
    /// The pull request the task made (`TaskPullRequestMonitor`), shown beside the harness.
    var pullRequest: TaskPullRequest? = nil
    var onOpenPullRequest: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The ports the task's processes listen on, after its pull request (`TaskHeaderActions.servers`).
    var servers: (SessionRecord) -> [TaskServerPort] = { _ in [] }
    var onOpenServer: (SessionRecord, TaskServerPort) -> Void = { _, _ in }
    /// The task's find in its conversation, for the header's Find button.
    var conversationFind: ConversationFindModel? = nil
    /// The split view the window shows, whose name opens its actions in its window tab. The title bar
    /// stands over a split view only for the window's tabs: each pane's header heads its task.
    var splitTitle: SplitViewTitleMenu? = nil
    /// The new-task screen's panels, when the tab shows it: its header has the terminal and side
    /// panel buttons, as a task's has (the Claude app's New session header, the Codex app's new thread).
    var draftPanels: Binding<TaskSurfaceNavigationProjection.PanelState>? = nil
    /// The window's tabs, when it has two or more.
    var tabs: TitleBarTabs? = nil
    /// What a screen in a task's place shows as its title, such as an archived task read beside the
    /// archived list; nil shows none.
    var title: String? = nil
    /// A screen's own row in the bar's place, with its own drag region: the calendar's month and buttons.
    var accessory: AnyView? = nil

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.windowDrag) private var drag
    /// The task part's width, which folds the panel buttons into a menu when it is narrow.
    @State private var headerWidth: CGFloat = .infinity
    /// Without the tab bar, the title bar takes a pane or a task dragged onto it as the bar would: the
    /// task gets a tab of its own, after the one tab there is.
    @State private var frame: CGRect = .zero
    @State private var token = UUID()

    private var headerActions: TaskHeaderActions {
        TaskHeaderActions(
            isAttached: { [isAttached] _ in isAttached }, onResume: onResume, onRename: onRename,
            onRenameFromConversation: onRenameFromConversation, onTogglePinned: onTogglePinned, onArchive: onArchive, onBackToConversation: onBackToConversation,
            projectName: projectName, projectMoveOptions: projectMoveOptions, onMoveToProject: onMoveToProject,
            onChooseAccount: onChooseAccount, canOpenOriginalConversation: canOpenOriginalConversation,
            onOpenOriginalConversation: onOpenOriginalConversation,
            pullRequest: { [pullRequest] _ in pullRequest }, onOpenPullRequest: onOpenPullRequest,
            servers: servers, onOpenServer: onOpenServer)
    }

    private var isFolded: Bool {
        // With the window's tabs, the shown tab holds the title and the tabs need their room as well.
        let tabsRoom = tabs.map { WindowTabMetrics.roomBeyondTitle(count: $0.tabs.count) * interfaceScale } ?? 0
        return TaskHeaderFold.folds(headerWidth: headerWidth - tabsRoom, interfaceScale: interfaceScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarVisible {
                TitleBarSidebarPart(isSidebarVisible: false, width: TitleBarSidebarPart.collapsedWidth,
                                    onToggleSidebar: onToggleSidebar, onNewTask: onNewTask)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
            }

            HStack(spacing: 8) {
                if let tabs {
                    WindowTabStrip(tabs: tabs.tabs, selection: tabs.selection, onSelect: tabs.onSelect,
                                   onClose: tabs.onClose, onCloseOthers: tabs.onCloseOthers, onNewTab: tabs.onNewTab,
                                   onOpenTask: tabs.onOpenTask, selectedTitle: { selectedTitle })
                        .layoutPriority(1)
                    WindowDragRegion().frame(minWidth: 24, maxWidth: .infinity)
                    if let session {
                        TaskHeaderStatus(session: session, actions: headerActions, showsHarness: false)
                            .id(session.id)
                    }
                    controls
                } else if let session {
                    TaskHeaderIdentity(session: session, actions: headerActions)
                        .id(session.id)
                        .layoutPriority(1)
                    if isDropTarget { TabInsertionMark() }
                    WindowDragRegion().frame(minWidth: 8, maxWidth: .infinity)
                    controls
                } else if let accessory {
                    accessory
                } else {
                    if let title {
                        Text(title)
                            .font(.system(size: 13 * interfaceScale, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsHitTesting(false)
                    }
                    WindowDragRegion().frame(maxWidth: .infinity)
                    controls
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .background(ParityTheme.canvas)
        }
        .frame(height: ParityTheme.titleBarHeight)
        .accessibilitySortPriority(ParityAccessibility.titleBar)
        .focusSection()
        .onChange(of: frame, initial: true) { registerAsTabBar() }
        .onChange(of: tabs == nil) { registerAsTabBar() }
        .onDisappear { drag?.removeWindowTabs(token: token) }
    }

    /// Stands in for the tab bar while there is none; the bar registers itself once there are two tabs.
    private func registerAsTabBar() {
        guard tabs == nil, session != nil, frame != .zero else {
            return drag?.removeWindowTabs(token: token) ?? ()
        }
        drag?.setWindowTabs(WindowDropGeometry.Strip(frame: frame, tabs: []), token: token)
    }

    private var isDropTarget: Bool {
        guard tabs == nil, case .windowTabs? = drag?.target else { return false }
        return true
    }

    /// The shown item's title in the tab that shows it: a task's or a split view's opens its actions.
    @ViewBuilder
    private var selectedTitle: some View {
        if let session {
            TaskTitleMenu(session: session, actions: headerActions, size: 12.5 * interfaceScale)
                .id(session.id)
        } else if let splitTitle {
            splitTitle
        } else {
            // The tab drags by it, as by the rest of the tab.
            Text(L10n.string("New task"))
                .font(.system(size: 12.5 * interfaceScale, weight: .medium))
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }

    /// The task's buttons, or the new-task screen's; a split view's are in its panes.
    @ViewBuilder
    private var controls: some View {
        if let session {
            TaskSurfaceControls(showsSessionRail: sessionRail?.visibility.isOnScreen(session.id) ?? showsSessionRail,
                                onToggleSessionRail: onToggleSessionRail,
                                panelState: $panelState, focusedSurface: focusedSurface, isFolded: isFolded,
                                find: conversationFind)
                // Native shortcut registrations must release the previous task's binding.
                .id(session.id)
        } else if let draftPanels {
            TaskSurfaceControls(showsSessionRail: false, onToggleSessionRail: {},
                                panelState: draftPanels, focusedSurface: focusedSurface,
                                isFolded: isFolded, offersSessionRail: false)
        }
    }
}

/// Keeps the window's buttons centred on the title bar's row: attached to the window's content, whose
/// top is the window's.
struct WindowChromeAlignmentAnchor: View {
    var body: some View {
        WindowChromeAlignment(targetCenterFromTop: ParityTheme.titleBarHeight / 2)
    }
}

/// The activity view's state for its button.
struct ActivityViewToggle {
    var isOn: Bool
    /// A task waits for the person or holds an unread result (`TaskAttentionState.needsAttention`).
    var needsAttention: Bool
    var toggle: () -> Void

    /// The Codex app's labels (`sidebarElectron.priorityThreads.*`): "Turn off activity view"
    /// while it is on, otherwise "View activity", with ", needs attention" when a task needs it.
    var accessibilityLabel: String {
        if isOn { return L10n.string("Turn off activity view") }
        return L10n.string(needsAttention ? "View activity, needs attention" : "View activity")
    }

    var help: String { TaskCommandTitle.activity(isShown: isOn) }
}

/// The Codex sidebar header's activity button: a bell, with a blue badge while a task needs
/// attention, filled in while the view is on.
struct ActivityViewButton: View {
    let toggle: ActivityViewToggle
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle.toggle) {
            icon
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(toggle.isOn ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear))
                }
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .help(ShortcutHelp.text(toggle.help, MacShortcut.toggleActivityView.binding))
        .accessibilityLabel(toggle.accessibilityLabel)
        .accessibilityHint(L10n.string("See chats that are unread, active, or awaiting a response"))
        .accessibilityAddTraits(toggle.isOn ? .isSelected : [])
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if toggle.needsAttention {
            Image(systemName: "bell.badge")
                .symbolRenderingMode(.palette)
                .foregroundStyle(ParityTheme.accent, Color.primary)
        } else {
            Image(systemName: "bell")
                .foregroundStyle(.primary)
        }
    }
}

private struct WindowChromeAlignment: NSViewRepresentable {
    let targetCenterFromTop: CGFloat

    func makeNSView(context: Context) -> WindowChromeAlignmentView {
        WindowChromeAlignmentView(targetCenterFromTop: targetCenterFromTop)
    }

    func updateNSView(_ nsView: WindowChromeAlignmentView, context: Context) {
        nsView.targetCenterFromTop = targetCenterFromTop
        nsView.applyAlignment()
    }
}

/// AppKit puts the window's buttons back in their own place whenever it updates the title bar: on a resize, and
/// on a new title or subtitle, as a remote window's connection line sets. Each move of a button asks for this
/// view's layout, which moves the buttons to the row before the window draws again.
private final class WindowChromeAlignmentView: NSView {
    var targetCenterFromTop: CGFloat
    /// Set while this view moves the buttons, so their own moves do not ask for another layout.
    private var isAligning = false
    private var observedButtons: [ObjectIdentifier] = []

    init(targetCenterFromTop: CGFloat) {
        self.targetCenterFromTop = targetCenterFromTop
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            removeButtonObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        applyAlignment()
    }

    private func observe(_ buttons: [NSButton]) {
        let identifiers = buttons.map(ObjectIdentifier.init)
        guard identifiers != observedButtons else { return }
        removeButtonObservers()
        observedButtons = identifiers
        for button in buttons {
            // Delivered as AppKit moves the button, so the layout it asks for comes before the window draws.
            NotificationCenter.default.addObserver(self, selector: #selector(buttonFrameDidChange),
                                                   name: NSView.frameDidChangeNotification, object: button)
        }
    }

    @objc private func buttonFrameDidChange(_ notification: Notification) {
        guard !isAligning else { return }
        needsLayout = true
    }

    private func removeButtonObservers() {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        observedButtons.removeAll()
    }

    func applyAlignment() {
        guard let window else { return }
        isAligning = true
        defer { isAligning = false }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
        observe(buttons)

        let targetYInHeader = isFlipped
            ? bounds.minY + targetCenterFromTop
            : bounds.maxY - targetCenterFromTop
        let targetCenterInWindow = convert(NSPoint(x: bounds.midX, y: targetYInHeader), to: nil)
        for button in buttons {
            // In full screen the buttons are in the title bar AppKit shows at the screen's top, and stay where it puts them.
            guard button.window === window, let bar = button.superview else { continue }
            // Each button, not their bar: AppKit places a button where it belongs in the window whatever the bar's
            // offset, so moving the bar again after each update would push it further down until the buttons left it.
            let originY = bar.convert(targetCenterInWindow, from: nil).y - button.frame.height / 2
            guard abs(button.frame.origin.y - originY) > 0.25 else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: originY))
        }
    }
}

struct WindowInitialFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowInitialFocusResetView {
        WindowInitialFocusResetView()
    }

    func updateNSView(_ nsView: WindowInitialFocusResetView, context: Context) {}
}

final class WindowInitialFocusResetView: NSView {
    private var didResetInitialFocus = false
    private var keyWindowObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyWindowObserver()
        guard let window, !didResetInitialFocus else { return }
        if window.isKeyWindow {
            scheduleInitialFocusReset(in: window)
        } else {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, let window else { return }
                    self.scheduleInitialFocusReset(in: window)
                }
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            removeKeyWindowObserver()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func scheduleInitialFocusReset(in window: NSWindow) {
        guard !didResetInitialFocus else { return }
        didResetInitialFocus = true
        removeKeyWindowObserver()
        let userActivatedWindow = ParityInteraction.currentEventIsFocusInteraction
        DispatchQueue.main.async { [weak window] in
            // A click or key that activates a background window may also focus a new panel.
            // Clear only launch-time default focus, never that explicit user handoff.
            guard !userActivatedWindow, !ParityInteraction.currentEventIsFocusInteraction else { return }
            if window?.firstResponder is NSTextView || window?.firstResponder is NSTextField {
                return
            }
            window?.makeFirstResponder(nil)
        }
    }

    private func removeKeyWindowObserver() {
        guard let keyWindowObserver else { return }
        NotificationCenter.default.removeObserver(keyWindowObserver)
        self.keyWindowObserver = nil
    }
}
