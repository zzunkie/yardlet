import SwiftUI

/// A pinned sidebar row the menu can open with `⌃1`–`⌃9`.
struct PinnedRowMenuItem: Identifiable, Equatable {
    let id: WindowItem
    let title: String
}

/// The window-layer actions the shell exposes to the menu bar. Panes have no toolbar of their
/// own; the menu, the command palette, and the sidebar rows are the entry points.
struct YardletSplitCommandSet {
    var canSplitRight = false
    var canSplitDown = false
    var canClosePane = false
    var pinnedRows: [PinnedRowMenuItem] = []
    var selection: WindowItem = .home
    var splitRight: () -> Void = {}
    var splitDown: () -> Void = {}
    var closePane: () -> Void = {}
    var dissolve: () -> Void = {}
    var focusPane: (PaneFocusDirection) -> Void = { _ in }
    var activate: (WindowItem) -> Void = { _ in }
    var tabs = YardletTabCommandSet()
}

/// The window's task tabs (`SplitStore.tabs`) for the File and Window menus.
struct YardletTabCommandSet {
    var canCloseTab = false
    var canReopenClosedTab = false
    var newTab: () -> Void = {}
    var closeTab: () -> Void = {}
    var selectNextTab: () -> Void = {}
    var selectPreviousTab: () -> Void = {}
    var reopenClosedTab: () -> Void = {}
}

/// macOS's own keys for tabs, as Safari, Finder and Terminal have them: ⌘T New Tab, ⌘W Close Tab
/// (the window's last tab closes the window, as Close did), ⌘⇧W Close Window, ⌘⇧T Reopen Closed
/// Tab, ⌃Tab and ⌃⇧Tab Show Next / Previous Tab. The Claude app's Code tab and the Codex app use
/// ⌃Tab, ⌘W and ⌘⇧T the same way for sessions and panel tabs. `⌘⇧[` / `⌘⇧]` stay with the sidebar's
/// previous and next task, and `⌘1`–`⌘9` with the task surfaces and pinned rows. With one tab, ⌃Tab
/// and ⌃⇧Tab are the next and previous task, as in the Claude app's Code sidebar (the Codex app's
/// ⌃Tab does nothing without a second tab).
enum TabCommandShortcut {
    static let newTab = KeyboardShortcut("t", modifiers: .command)
    static let closeTab = KeyboardShortcut("w", modifiers: .command)
    static let closeWindow = KeyboardShortcut("w", modifiers: [.command, .shift])
    static let reopenClosedTab = KeyboardShortcut("t", modifiers: [.command, .shift])
    static let nextTab = KeyboardShortcut(.tab, modifiers: .control)
    /// A keyboard sends ⇧Tab as the back-tab character, which a menu item matches only when its
    /// key is that character (`NSBackTabCharacter`), not Tab with Shift.
    static let previousTab = KeyboardShortcut(KeyEquivalent("\u{19}"), modifiers: [.control, .shift])
}

struct YardletTabCommands: Commands {
    @FocusedValue(\.yardletSplitCommands) private var split
    @FocusedValue(\.yardletTaskCommands) private var task

    private var tabs: YardletTabCommandSet? { split?.tabs }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("New Tab")) { tabs?.newTab() }
                .keyboardShortcut(TabCommandShortcut.newTab)
                .disabled(tabs == nil)
        }
        CommandGroup(replacing: .saveItem) {
            if let tabs, tabs.canCloseTab {
                Button(L10n.string("Close Tab")) { tabs.closeTab() }
                    .keyboardShortcut(TabCommandShortcut.closeTab)
                Button(L10n.string("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(TabCommandShortcut.closeWindow)
            } else {
                Button(L10n.string("Close")) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(TabCommandShortcut.closeTab)
            }
            Button(L10n.string("Reopen Closed Tab")) { tabs?.reopenClosedTab() }
                .keyboardShortcut(TabCommandShortcut.reopenClosedTab)
                .disabled(!(tabs?.canReopenClosedTab ?? false))
        }
        CommandGroup(before: .windowArrangement) {
            if tabs?.canCloseTab ?? false {
                Button(L10n.string("Show Previous Tab")) { tabs?.selectPreviousTab() }
                    .keyboardShortcut(TabCommandShortcut.previousTab)
                Button(L10n.string("Show Next Tab")) { tabs?.selectNextTab() }
                    .keyboardShortcut(TabCommandShortcut.nextTab)
            } else {
                Button(L10n.string("Previous task")) {
                    if let row = task?.targets.previousRow { task?.activate(row) }
                }
                .keyboardShortcut(TabCommandShortcut.previousTab)
                .disabled(task?.targets.previousRow == nil)
                Button(L10n.string("Next task")) {
                    if let row = task?.targets.nextRow { task?.activate(row) }
                }
                .keyboardShortcut(TabCommandShortcut.nextTab)
                .disabled(task?.targets.nextRow == nil)
            }
            Divider()
        }
    }
}

private struct YardletSplitCommandsKey: FocusedValueKey {
    typealias Value = YardletSplitCommandSet
}

extension FocusedValues {
    var yardletSplitCommands: YardletSplitCommandSet? {
        get { self[YardletSplitCommandsKey.self] }
        set { self[YardletSplitCommandsKey.self] = newValue }
    }
}

enum SplitCommandTitle {
    static func split(_ direction: SplitDirection) -> String {
        switch direction {
        case .right: L10n.string("Split pane right")
        case .down: L10n.string("Split pane down")
        case .left: L10n.string("Split pane left")
        case .up: L10n.string("Split pane up")
        }
    }

    static func focus(_ direction: PaneFocusDirection) -> String {
        switch direction {
        case .left: L10n.string("Focus pane left")
        case .right: L10n.string("Focus pane right")
        case .up: L10n.string("Focus pane above")
        case .down: L10n.string("Focus pane below")
        }
    }

    static func focusShortcut(_ direction: PaneFocusDirection) -> KeyEquivalent {
        switch direction {
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        }
    }

    static func focusSymbol(_ direction: PaneFocusDirection) -> String {
        switch direction {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

/// `⌘1`–`⌘4` stay bound to the session-layer surfaces, so the window layer uses `⌘⇧D`,
/// `⌘⌥⇧D`, `⌘⌃W`, `⌘⌥` arrows, and `⌃1`–`⌃9` for pinned rows.
struct YardletWindowLayerCommands: Commands {
    @FocusedValue(\.yardletSplitCommands) private var split

    var body: some Commands {
        CommandMenu(Text(L10n.string("Split View"))) {
            Button(SplitCommandTitle.split(.right)) { split?.splitRight() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(split?.canSplitRight ?? false))
            Button(SplitCommandTitle.split(.down)) { split?.splitDown() }
                .keyboardShortcut("d", modifiers: [.command, .shift, .option])
                .disabled(!(split?.canSplitDown ?? false))
            Button(L10n.string("Close pane")) { split?.closePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(!(split?.canClosePane ?? false))
            Button(L10n.string("End split view")) { split?.dissolve() }
                .disabled(!(split?.canClosePane ?? false))

            Divider()

            ForEach(PaneFocusDirection.allCases, id: \.self) { direction in
                Button(SplitCommandTitle.focus(direction)) { split?.focusPane(direction) }
                    .keyboardShortcut(
                        SplitCommandTitle.focusShortcut(direction),
                        modifiers: [.command, .option]
                    )
                    .disabled(!(split?.canClosePane ?? false))
            }

            if let pinned = split?.pinnedRows, !pinned.isEmpty {
                Divider()
                ForEach(Array(pinned.prefix(9).enumerated()), id: \.element.id) { index, item in
                    Button {
                        split?.activate(item.id)
                    } label: {
                        if item.id == split?.selection {
                            Label(item.title, systemImage: "checkmark")
                        } else {
                            Text(item.title)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                }
            }
        }
    }
}
