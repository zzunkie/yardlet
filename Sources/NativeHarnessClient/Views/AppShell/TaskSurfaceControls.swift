import SwiftUI

extension TaskSurface {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .diff: "2"
        case .terminal: "3"
        case .browser: "4"
        }
    }
}

/// The symbols of a task header's panel buttons, which the command palette's items for the same panels
/// share. The terminal's is the one its tab and pane show.
enum TaskPanelSymbol {
    static let sessionRail = "checklist"
    static let terminal = "terminal"
    static let sidePanel = "sidebar.right"
}

/// A task header's buttons: find in the conversation, then the session rail (where the Environment
/// popover was), the terminal below the conversation, and the side panel. In the title bar they act on
/// the task the window shows; in a split pane's header, on that pane's task. A header too narrow for
/// them shows them in a "More" menu instead, as the Claude app's header does.
struct TaskSurfaceControls: View {
    /// The session rail is on screen for the task.
    let showsSessionRail: Bool
    let onToggleSessionRail: () -> Void
    @Binding var panelState: TaskSurfaceNavigationProjection.PanelState
    /// The window's focus for the buttons; nil in a pane that is not focused, whose buttons are reached
    /// by pointer and VoiceOver.
    var focusedSurface: FocusState<TaskSurface?>.Binding?
    /// Shows the buttons in a "More" menu.
    var isFolded = false
    /// Registers `⌘1`–`⌘4` for the task. Only one header does: the title bar's, or the focused pane's.
    var registersShortcuts = true
    /// Called before a button acts, so a pane's button also focuses its pane.
    var onActivate: () -> Void = {}
    /// The new-task screen has no task for a rail or a review: its header has the terminal and the side
    /// panel, and `⌘1`, `⌘3`, `⌘4` (the Claude app's New session header has Terminal, Browser and Files).
    var offersSessionRail = true
    /// Panels the window cannot show yet (another Mac's window, for a panel its host does not serve): their buttons and
    /// keys show dimmed.
    var unavailableSurfaces: Set<TaskSurface> = []
    /// The task's find in its conversation, for the Find button; nil where there is no conversation,
    /// as on the new-task screen.
    var find: ConversationFindModel? = nil
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @AppStorage(TerminalLocation.key) private var terminalLocation = TerminalLocation.bottom.rawValue

    private var toolbarSurfaces: [TaskSurface] {
        offersSessionRail ? [.diff, .terminal, .browser] : [.terminal, .browser]
    }

    private var shortcutSurfaces: [TaskSurface] {
        offersSessionRail ? TaskSurface.allCases : [.chat, .terminal, .browser]
    }

    var body: some View {
        Group {
            if isFolded {
                foldedMenu
            } else {
                HStack(spacing: 4) {
                    if let find {
                        findButton(find)
                    }
                    ForEach(toolbarSurfaces) { surface in
                        button(surface)
                    }
                }
            }
        }
        .background {
            // Keep existing commands registered independently of the visible panel toggles.
            if registersShortcuts {
                ForEach(shortcutSurfaces.filter { !unavailableSurfaces.contains($0) }) { surface in
                    Button { act(surface) } label: { EmptyView() }
                        .keyboardShortcut(surface.keyboardShortcut, modifiers: .command)
                        .focusable(false).hidden().accessibilityHidden(true)
                }
            }
        }
        .fixedSize()
        .focusSection()
        .accessibilitySortPriority(ParityAccessibility.surfacePicker)
    }

    private func button(_ surface: TaskSurface) -> some View {
        Button {
            press(surface)
        } label: {
            label(symbol(surface), isActive: isActive(surface))
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(unavailableSurfaces.contains(surface))
        .modifier(OptionalSurfaceFocus(binding: focusedSurface, surface: surface))
        .accessibilityLabel(controlTitle(surface))
        .accessibilityAddTraits(isActive(surface) ? .isSelected : [])
        .accessibilityValue(isActive(surface) ? L10n.string("Selected") : "")
        .accessibilityHint(L10n.string("Show or hide this task panel"))
        .help(ShortcutHelp.text(controlTitle(surface), menuShortcut(surface)))
        .onMoveCommand { direction in
            if direction == .left { move(from: surface, by: -1) }
            if direction == .right { move(from: surface, by: 1) }
        }
    }

    /// The bar is the conversation's own (`ConversationFindBar`): the button opens it as Edit › Find does,
    /// and closes it as its close button does.
    private func findButton(_ find: ConversationFindModel) -> some View {
        Button {
            pressFind(find)
        } label: {
            label(Self.findSymbol, isActive: find.isPresented)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(findTitle(find))
        .accessibilityAddTraits(find.isPresented ? .isSelected : [])
        .help(ShortcutHelp.text(findTitle(find), find.isPresented ? nil : ConversationFindShortcut.find))
    }

    private func label(_ symbol: String, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(minWidth: 28, minHeight: 28)
            .background(isActive ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }

    /// The Claude app's overflow menu for a narrow header: the same buttons, by their titles.
    private var foldedMenu: some View {
        Menu {
            if let find {
                Button {
                    pressFind(find)
                } label: {
                    Label(findTitle(find), systemImage: Self.findSymbol)
                }
            }
            ForEach(toolbarSurfaces) { surface in
                Button {
                    press(surface)
                } label: {
                    Label(controlTitle(surface), systemImage: symbol(surface))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .parityPointer()
        .accessibilityLabel(L10n.string("More"))
        .help(L10n.string("More"))
    }

    private func symbol(_ surface: TaskSurface) -> String {
        switch surface {
        case .browser: TaskPanelSymbol.sidePanel
        case .terminal: TaskPanelSymbol.terminal
        case .diff, .chat: TaskPanelSymbol.sessionRail
        }
    }

    private static let findSymbol = "magnifyingglass"

    private func findTitle(_ find: ConversationFindModel) -> String {
        L10n.string(find.isPresented ? "Close find" : "Find in chat")
    }

    private func pressFind(_ find: ConversationFindModel) {
        onActivate()
        if find.isPresented {
            find.close(fallingBackTo: keyboardFocus)
        } else {
            find.openFromKeyWindow()
        }
    }

    private func press(_ surface: TaskSurface) {
        onActivate()
        if surface == .diff { onToggleSessionRail() }
        else if surface == .browser { toggleWorkspace() }
        else { toggle(surface) }
    }

    /// `⌘1`–`⌘4`: the conversation alone, or a panel shown or hidden.
    private func act(_ surface: TaskSurface) {
        onActivate()
        toggle(surface)
    }

    /// The View menu's key for what the button does: the rail, the side panel or the terminal.
    private func menuShortcut(_ surface: TaskSurface) -> KeyboardShortcut? {
        switch surface {
        case .diff: TaskCommandShortcut.toggleSessionRail
        case .browser: TaskCommandShortcut.toggleSidePanel
        case .terminal: TaskCommandShortcut.toggleTerminal
        case .chat: nil
        }
    }

    private func controlTitle(_ surface: TaskSurface) -> String {
        if surface == .diff { return L10n.string(showsSessionRail ? "Hide session rail" : "Show session rail") }
        if surface == .browser { return TaskCommandTitle.sidePanel(isShown: panelState.trailingSurfaceID != nil) }
        if surface == .terminal { return TaskCommandTitle.terminal(isShown: panelState.showsTerminal) }
        return surface.displayName
    }


    private func toggleWorkspace() {
        panelState = TaskSurfaceNavigationProjection.toggledPanelState(
            current: panelState, targetID: TaskSurfaceNavigationProjection.sidePanelToggleID
        )
        focusedSurface?.wrappedValue = nil
        // A click shows the panel's last tab without taking focus from the composer.
        if panelState.trailingSurfaceID != nil, !ParityInteraction.currentEventIsKeyboard {
            keyboardFocus?.cancel()
            return
        }
        keyboardFocus?.move(to: TaskFocusTarget.visibleContent(in: panelState))
    }

    private func toggle(_ surface: TaskSurface) {
        panelState = TaskSurfaceNavigationProjection.toggledPanelState(
            current: panelState, targetID: surface.rawValue,
            terminalLocation: TerminalLocation(rawValue: terminalLocation) ?? .bottom
        )
        focusedSurface?.wrappedValue = nil
        keyboardFocus?.move(to: .destination(for: surface, panels: panelState))
    }

    private func move(from current: TaskSurface, by offset: Int) {
        guard let id = TaskSurfaceNavigationProjection.targetSurfaceID(
            in: toolbarSurfaces.map(\.rawValue),
            focusedID: current.rawValue,
            offset: offset
        ), let surface = TaskSurface(rawValue: id) else { return }
        focusedSurface?.wrappedValue = surface
    }

    private func isActive(_ surface: TaskSurface) -> Bool {
        switch surface {
        case .chat: panelState.trailingSurfaceID == nil && !panelState.isTerminalPresented
        case .diff: showsSessionRail
        case .browser: panelState.trailingSurfaceID != nil
        case .terminal: panelState.showsTerminal
        }
    }
}

/// A button joins the window's focus for the task buttons where the header has it.
private struct OptionalSurfaceFocus: ViewModifier {
    let binding: FocusState<TaskSurface?>.Binding?
    let surface: TaskSurface

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: surface)
        } else {
            content
        }
    }
}
