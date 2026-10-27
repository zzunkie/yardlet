import SwiftUI

enum TaskSurface: String, CaseIterable, Identifiable {
    case chat, diff, terminal, browser

    var id: Self { self }

    var displayName: String {
        switch self {
        case .chat: L10n.string("Chat")
        case .diff: L10n.string("Changes")
        case .terminal: L10n.string("Terminal")
        case .browser: L10n.string("Browser")
        }
    }

    var symbolName: String {
        switch self {
        case .chat: "text.bubble"
        case .diff: "plusminus"
        case .terminal: "terminal"
        case .browser: "safari"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .diff: "2"
        case .terminal: "3"
        case .browser: "4"
        }
    }
}

/// A task header's buttons: the session rail (where the Environment popover was), the terminal
/// below the conversation, and the side panel. In the title bar they act on the task the window
/// shows; in a split pane's header, on that pane's task. A header too narrow for them shows them in a
/// "More" menu instead, as the Claude app's header does.
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
    @Environment(\.taskKeyboardFocus) private var keyboardFocus

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
                    ForEach(toolbarSurfaces) { surface in
                        button(surface)
                    }
                }
            }
        }
        .background {
            // Keep existing commands registered independently of the visible panel toggles.
            if registersShortcuts {
                ForEach(shortcutSurfaces) { surface in
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
            HStack(spacing: 5) {
                Image(systemName: symbol(surface))
                    .font(.system(size: 12))
            }
            .foregroundStyle(isActive(surface) ? Color.primary : Color.secondary)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                isActive(surface) ? ParityTheme.selectedFill : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
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

    /// The Claude app's overflow menu for a narrow header: the same three, by their titles.
    private var foldedMenu: some View {
        Menu {
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
        surface == .browser ? "sidebar.right" : (surface == .terminal ? "rectangle.bottomthird.inset.filled" : "sidebar.squares.right")
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
        if surface == .terminal { return TaskCommandTitle.terminal(isShown: panelState.isTerminalPresented) }
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
            current: panelState, targetID: surface.rawValue
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
        case .terminal: panelState.isTerminalPresented
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
