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
    /// The shown split view's sidebar row actions, which its window tab's name also opens.
    var isSplitPinned = false
    var renameSplit: () -> Void = {}
    var togglePinnedSplit: () -> Void = {}
    var archiveSplit: () -> Void = {}
    var focusPane: (PaneFocusDirection) -> Void = { _ in }
    /// The focused pane is shown alone over its split view for now.
    var isPaneMaximized = false
    var toggleMaximizedPane: () -> Void = {}
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

struct YardletTabCommands: Commands {
    @FocusedValue(\.yardletSplitCommands) private var split
    @FocusedValue(\.yardletTaskCommands) private var task

    private var tabs: YardletTabCommandSet? { split?.tabs }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("New Tab")) { tabs?.newTab() }
                .keyboardShortcut(MacShortcut.newTab.menuBinding)
                .disabled(tabs == nil)
        }
        CommandGroup(replacing: .saveItem) {
            if let tabs, tabs.canCloseTab {
                Button(L10n.string("Close Tab")) { tabs.closeTab() }
                    .keyboardShortcut(MacShortcut.closeTab.menuBinding)
                Button(L10n.string("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(MacShortcut.closeWindow.menuBinding)
            } else {
                Button(L10n.string("Close")) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(MacShortcut.closeTab.menuBinding)
            }
            Button(L10n.string("Reopen Closed Tab")) { tabs?.reopenClosedTab() }
                .keyboardShortcut(MacShortcut.reopenClosedTab.menuBinding)
                .disabled(!(tabs?.canReopenClosedTab ?? false))
        }
        CommandGroup(before: .windowArrangement) {
            if tabs?.canCloseTab ?? false {
                Button(L10n.string("Show Previous Tab")) { tabs?.selectPreviousTab() }
                    .keyboardShortcut(MacShortcut.previousTab.menuBinding)
                Button(L10n.string("Show Next Tab")) { tabs?.selectNextTab() }
                    .keyboardShortcut(MacShortcut.nextTab.menuBinding)
            } else {
                Button(L10n.string("Previous task")) {
                    if let row = task?.targets.previousRow { task?.activate(row) }
                }
                .keyboardShortcut(MacShortcut.previousTab.menuBinding)
                .disabled(task?.targets.previousRow == nil)
                Button(L10n.string("Next task")) {
                    if let row = task?.targets.nextRow { task?.activate(row) }
                }
                .keyboardShortcut(MacShortcut.nextTab.menuBinding)
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

    /// Maximize pane, or Restore split view while a pane is shown alone.
    static func maximize(isMaximized: Bool) -> String {
        L10n.string(isMaximized ? "Restore split view" : "Maximize pane")
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

struct YardletWindowLayerCommands: Commands {
    @FocusedValue(\.yardletSplitCommands) private var split

    var body: some Commands {
        CommandMenu(Text(L10n.string("Split View"))) {
            Button(SplitCommandTitle.split(.right)) { split?.splitRight() }
                .keyboardShortcut(MacShortcut.splitRight.menuBinding)
                .disabled(!(split?.canSplitRight ?? false))
            Button(SplitCommandTitle.split(.down)) { split?.splitDown() }
                .keyboardShortcut(MacShortcut.splitDown.menuBinding)
                .disabled(!(split?.canSplitDown ?? false))
            Button(L10n.string("Close pane")) { split?.closePane() }
                .keyboardShortcut(MacShortcut.closePane.menuBinding)
                .disabled(!(split?.canClosePane ?? false))
            Button(SplitCommandTitle.maximize(isMaximized: split?.isPaneMaximized ?? false)) {
                split?.toggleMaximizedPane()
            }
            .keyboardShortcut(MacShortcut.maximizePane.menuBinding)
            .disabled(!(split?.canClosePane ?? false))
            Button(L10n.string("End split view")) { split?.dissolve() }
                .disabled(!(split?.canClosePane ?? false))

            Divider()

            Button(L10n.string("Rename split view…")) { split?.renameSplit() }
                .disabled(!(split?.canClosePane ?? false))
            Button(L10n.string(split?.isSplitPinned == true ? "Unpin split view" : "Pin split view")) {
                split?.togglePinnedSplit()
            }
            .disabled(!(split?.canClosePane ?? false))
            Button(L10n.string("Archive tasks…")) { split?.archiveSplit() }
                .disabled(!(split?.canClosePane ?? false))

            Divider()

            ForEach(PaneFocusDirection.allCases, id: \.self) { direction in
                Button(SplitCommandTitle.focus(direction)) { split?.focusPane(direction) }
                    .keyboardShortcut(MacShortcut.focus(direction).menuBinding)
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
                    .keyboardShortcut(MacShortcut.pinnedRow(index + 1).menuBinding)
                }
            }
        }
    }
}
