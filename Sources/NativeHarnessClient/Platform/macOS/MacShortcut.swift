import AppKit
import SwiftUI

/// A Mac command's identity stays the same when a menu title or a keyboard layout changes.
/// Dispatch stays with the menu, responder or focused control that owns the command.
enum MacShortcut: Hashable, Identifiable {
    case settings, palette, help, newTask, toggleSidebar, previousTask, nextTask, nextTaskNeedingAttention
    case toggleActivityView, togglePinned, markUnread, archive, toggleSessionRail, toggleSidePanel
    case toggleTerminal, terminalAlternate, openModelMenu, back, forward, newTab, closeTab, closeWindow
    case reopenClosedTab, nextTab, previousTab, splitRight, splitDown, closePane, maximizePane, focusLeft, focusRight
    case focusUp, focusDown, conversationFind, nextResult, previousResult, surfaceChat, surfaceReview
    case surfaceTerminal, surfaceBrowser, zoomIn, zoomOut, actualSize
    case composerSend, composerAlternate, composerNewline, composerEscape, start, acceptSuggestion, complete
    case pasteAttachment, leaveBash, previousSuggestion, nextSuggestion
    case attachSelection
    case browserNew, browserClose, browserReopen, browserNext, browserPrevious, browserCopy, browserCut
    case browserPaste, browserSelectAll, browserUndo, browserRedo, browserZoomIn, browserZoomOut
    case browserReset, browserFind, browserAddress, browserReload, browserBack, browserForward
    case browserEscape
    case simulatorHome, simulatorLock, simulatorClose
    case imageCopy, imagePrevious, imageNext, imageClose, imageZoomIn, imageZoomOut, imageFit, markupUndo
    case sendMail
    case palettePrevious, paletteNext, paletteChoose, paletteClose
    case previousItem, nextItem, chooseItem, chooseItemSpace, leftItem, rightItem, nextGroup, previousGroup
    case addressNext, addressPrevious, addressNextTab, addressPreviousTab, addressRemove
    case previousFindMatch, cancelDrag, confirmDialog, dismiss
    case pinnedRow(Int), browserTab(Int), modelOption(Int), answerOption(Int)

    var id: String {
        switch self {
        case let .pinnedRow(n): "pinnedRow.\(n)"
        case let .browserTab(n): "browserTab.\(n)"
        case let .modelOption(n): "modelOption.\(n)"
        case let .answerOption(n): "answerOption.\(n)"
        default: String(describing: self)
        }
    }

    struct Definition {
        let scope: String
        let title: String
        let key: KeyEquivalent
        let modifiers: EventModifiers

        init(_ scope: String, _ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers) {
            self.scope = scope
            self.title = title
            self.key = key
            self.modifiers = modifiers
        }
    }

    static let all: [Self] = [
        .settings, .palette, .help, .newTask, .toggleSidebar, .previousTask, .nextTask,
        .nextTaskNeedingAttention, .toggleActivityView, .togglePinned, .markUnread, .archive,
        .toggleSessionRail, .toggleSidePanel, .toggleTerminal, .terminalAlternate, .openModelMenu, .back,
        .forward, .newTab, .closeTab, .closeWindow, .reopenClosedTab, .nextTab, .previousTab, .splitRight,
        .splitDown, .closePane, .maximizePane, .focusLeft, .focusRight, .focusUp, .focusDown, .conversationFind,
        .nextResult, .previousResult, .surfaceChat, .surfaceReview, .surfaceTerminal, .surfaceBrowser,
        .actualSize, .zoomIn, .zoomOut,
        .composerSend, .composerAlternate, .composerNewline, .composerEscape, .start, .acceptSuggestion,
        .complete, .pasteAttachment, .leaveBash, .previousSuggestion, .nextSuggestion, .attachSelection,
        .browserNew, .browserClose, .browserReopen, .browserNext, .browserPrevious, .browserCopy,
        .browserCut, .browserPaste, .browserSelectAll, .browserUndo, .browserRedo, .browserZoomIn,
        .browserZoomOut, .browserReset, .browserFind, .browserAddress, .browserReload, .browserBack,
        .browserForward, .browserEscape, .simulatorHome, .simulatorLock, .simulatorClose, .imageCopy,
        .imagePrevious, .imageNext, .imageClose, .imageZoomIn, .imageZoomOut, .imageFit, .markupUndo,
        .sendMail, .palettePrevious, .paletteNext, .paletteChoose, .paletteClose,
        .previousItem, .nextItem, .chooseItem, .chooseItemSpace, .leftItem, .rightItem, .nextGroup, .previousGroup,
        .addressNext, .addressPrevious, .addressNextTab, .addressPreviousTab, .addressRemove,
        .previousFindMatch, .cancelDrag, .confirmDialog, .dismiss,
    ] + (1...9).flatMap { [.pinnedRow($0), .browserTab($0), .modelOption($0), .answerOption($0)] }

    var definition: Definition {
        switch self {
        case .settings: .init("Window", "Settings", ",", .command)
        case .palette: .init("Window", "Command palette", "k", .command)
        case .help: .init("Window", "Yardlet Help", "?", .command)
        case .newTask: .init("Window", "New task", "n", .command)
        case .toggleSidebar: .init("Window", "Show sidebar", "s", [.command, .shift])
        case .previousTask: .init("Window", "Previous task", "[", [.command, .shift])
        case .nextTask: .init("Window", "Next task", "]", [.command, .shift])
        case .nextTaskNeedingAttention: .init("Window", "Next task needing attention", "a", [.command, .option])
        case .toggleActivityView: .init("Window", "View activity", "u", [.command, .option])
        case .togglePinned: .init("Window", "Pin task", "p", [.command, .option])
        case .markUnread: .init("Window", "Mark task as unread", "u", [.command, .shift])
        case .archive: .init("Window", "Archive task", "a", [.command, .shift])
        case .toggleSessionRail: .init("Window", "Show session rail", "i", [.command, .control])
        case .toggleSidePanel: .init("Window", "Show side panel", "b", [.command, .option])
        case .toggleTerminal: .init("Window", "Show terminal", "j", .command)
        case .terminalAlternate: .init("Window", "Show terminal (alternate)", "`", .control)
        case .openModelMenu: .init("Window", "Select model", "m", [.control, .shift])
        case .back: .init("Window", "Back", "[", .command)
        case .forward: .init("Window", "Forward", "]", .command)
        case .newTab: .init("Window", "New Tab", "t", .command)
        case .closeTab: .init("Window", "Close Tab", "w", .command)
        case .closeWindow: .init("Window", "Close Window", "w", [.command, .shift])
        case .reopenClosedTab: .init("Window", "Reopen Closed Tab", "t", [.command, .shift])
        case .nextTab: .init("Window", "Show Next Tab", .tab, .control)
        case .previousTab: .init("Window", "Show Previous Tab", KeyEquivalent("\u{19}"), [.control, .shift])
        case .splitRight: .init("Window", "Split pane right", "d", [.command, .shift])
        case .splitDown: .init("Window", "Split pane down", "d", [.command, .shift, .option])
        case .closePane: .init("Window", "Close pane", "w", [.command, .control])
        case .maximizePane: .init("Window", "Maximize pane", .return, [.command, .control])
        case .focusLeft: .init("Window", "Focus pane left", .leftArrow, [.command, .option])
        case .focusRight: .init("Window", "Focus pane right", .rightArrow, [.command, .option])
        case .focusUp: .init("Window", "Focus pane above", .upArrow, [.command, .option])
        case .focusDown: .init("Window", "Focus pane below", .downArrow, [.command, .option])
        case .conversationFind: .init("Window", "Find", "f", .command)
        case .nextResult: .init("Window", "Next result", "g", .command)
        case .previousResult: .init("Window", "Previous result", "g", [.command, .shift])
        case .surfaceChat: .init("Window", "Chat", "1", .command)
        case .surfaceReview: .init("Window", "Review", "2", .command)
        case .surfaceTerminal: .init("Window", "Terminal", "3", .command)
        case .surfaceBrowser: .init("Window", "Browser", "4", .command)
        case .actualSize: .init("Window", "Actual Size", "0", .command)
        case .zoomIn: .init("Window", "Zoom In", "+", .command)
        case .zoomOut: .init("Window", "Zoom Out", "-", .command)
        case .composerSend: .init("Composer", "Send or allow once", .return, [])
        case .composerAlternate: .init("Composer", "Send alternate follow-up", .return, .command)
        case .composerNewline: .init("Composer", "Insert newline", .return, .shift)
        case .composerEscape: .init("Composer", "Dismiss, deny or stop", .escape, [])
        case .start: .init("Composer", "Start task", .return, .command)
        case .acceptSuggestion: .init("Composer", "Accept suggestion", .rightArrow, [])
        case .complete: .init("Composer", "Complete selection", .tab, [])
        case .pasteAttachment: .init("Composer", "Paste attachment", "v", .command)
        case .leaveBash: .init("Composer", "Leave bash mode", .delete, [])
        case .previousSuggestion: .init("Composer", "Previous suggestion", .upArrow, [])
        case .nextSuggestion: .init("Composer", "Next suggestion", .downArrow, [])
        case .attachSelection: .init("Terminal", "Attach Selection to Message", "l", [.command, .shift])
        case .browserNew: .init("Browser", "New Tab", "t", .command)
        case .browserClose: .init("Browser", "Close Tab", "w", .command)
        case .browserReopen: .init("Browser", "Reopen Closed Tab", "t", [.command, .shift])
        case .browserNext: .init("Browser", "Show Next Tab", .tab, .control)
        case .browserPrevious: .init("Browser", "Show Previous Tab", KeyEquivalent("\u{19}"), [.control, .shift])
        case .browserCopy: .init("Browser", "Copy", "c", .command)
        case .browserCut: .init("Browser", "Cut", "x", .command)
        case .browserPaste: .init("Browser", "Paste", "v", .command)
        case .browserSelectAll: .init("Browser", "Select All", "a", .command)
        case .browserUndo: .init("Browser", "Undo", "z", .command)
        case .browserRedo: .init("Browser", "Redo", "z", [.command, .shift])
        case .browserZoomIn: .init("Browser", "Zoom in", "=", .command)
        case .browserZoomOut: .init("Browser", "Zoom out", "-", .command)
        case .browserReset: .init("Browser", "Reset zoom", "0", .command)
        case .browserFind: .init("Browser", "Find", "f", .command)
        case .browserAddress: .init("Browser", "Focus address field", "l", .command)
        case .browserReload: .init("Browser", "Reload", "r", .command)
        case .browserBack: .init("Browser", "Back", "[", .command)
        case .browserForward: .init("Browser", "Forward", "]", .command)
        case .browserEscape: .init("Browser", "Dismiss browser overlay", .escape, [])
        case .simulatorHome: .init("Simulator", "Home", "h", [.command, .shift])
        case .simulatorLock: .init("Simulator", "Lock", "l", .command)
        case .simulatorClose: .init("Simulator", "Close Tab", "w", .command)
        case .imageCopy: .init("Images", "Copy", "c", .command)
        case .imagePrevious: .init("Images", "Previous image", .leftArrow, [])
        case .imageNext: .init("Images", "Next image", .rightArrow, [])
        case .imageClose: .init("Images", "Close", .escape, [])
        case .imageZoomIn: .init("Images", "Zoom in", "=", .command)
        case .imageZoomOut: .init("Images", "Zoom out", "-", .command)
        case .imageFit: .init("Images", "Fit to window", "0", .command)
        case .markupUndo: .init("Images", "Undo markup", "z", .command)
        case .sendMail: .init("Mail", "Send mail", .return, .command)
        case .palettePrevious: .init("Command palette", "Previous command", .upArrow, [])
        case .paletteNext: .init("Command palette", "Next command", .downArrow, [])
        case .paletteChoose: .init("Command palette", "Run command", .return, [])
        case .paletteClose: .init("Command palette", "Close command palette", .escape, [])
        case .previousItem: .init("Focused list", "Previous item", .upArrow, [])
        case .nextItem: .init("Focused list", "Next item", .downArrow, [])
        case .chooseItem: .init("Focused list", "Open selected item", .return, [])
        case .chooseItemSpace: .init("Focused list", "Open selected item (alternate)", .space, [])
        case .leftItem: .init("Focused control", "Move left", .leftArrow, [])
        case .rightItem: .init("Focused control", "Move right", .rightArrow, [])
        case .nextGroup: .init("Home", "Move between groups", .tab, [])
        case .previousGroup: .init("Home", "Move between groups (backtab)", KeyEquivalent("\u{19}"), .shift)
        case .addressNext: .init("Address field", "Next suggestion", .downArrow, [])
        case .addressPrevious: .init("Address field", "Previous suggestion", .upArrow, [])
        case .addressNextTab: .init("Address field", "Next suggestion (Tab)", .tab, [])
        case .addressPreviousTab: .init("Address field", "Previous suggestion (backtab)", KeyEquivalent("\u{19}"), .shift)
        case .addressRemove: .init("Address field", "Remove suggestion", .deleteForward, .shift)
        case .previousFindMatch: .init("Find bar", "Previous result", .return, .shift)
        case .confirmDialog: .init("Dialog", "Confirm", .return, [])
        case .dismiss: .init("Dialog or menu", "Dismiss", .escape, [])
        case .cancelDrag: .init("Window", "Cancel drag", .escape, [])
        case let .modelOption(number):
            .init("Select model", L10n.format("Select model %lld", Int64(number)), KeyEquivalent(Character(String(number))), [])
        case let .answerOption(number):
            .init("Question", L10n.format("Select option %lld", Int64(number)), KeyEquivalent(Character(String(number))), [])
        case let .pinnedRow(number):
            .init("Window", L10n.format("Open pinned item %lld", Int64(number)), KeyEquivalent(Character(String(number))), .control)
        case let .browserTab(number):
            .init("Browser", number == 9 ? L10n.string("Last browser tab") : L10n.format("Browser tab %lld", Int64(number)),
                  KeyEquivalent(Character(String(number))), .command)
        }
    }

    func defaultBinding(send: SendShortcut = .return) -> KeyboardShortcut {
        if self == .imageClose || self == .paletteClose || self == .dismiss { return .cancelAction }
        if self == .confirmDialog { return .defaultAction }
        let item = definition
        if self == .composerSend, send != .return { return KeyboardShortcut(.return, modifiers: .command) }
        if self == .composerAlternate, send != .return { return KeyboardShortcut(.return, modifiers: [.shift, .command]) }
        return KeyboardShortcut(item.key, modifiers: item.modifiers)
    }

    var isCustomized: Bool {
        let overrides = MacShortcutPreferences.shared.snapshot.overrides
        return !overrides.isEmpty && overrides[id] != nil
    }

    var binding: KeyboardShortcut? { MacShortcutPreferences.shared.binding(for: self) }

    /// AppKit applies title-specific user equivalents itself. Giving them back as the app's base
    /// binding would also assign them to a different title of the same command.
    var menuBinding: KeyboardShortcut? {
        let prefs = MacShortcutPreferences.shared
        if prefs.snapshot.system.contains(where: { $0.commands.contains(self) }) { return defaultBinding() }
        return prefs.binding(for: self)
    }

    @MainActor func matches(_ press: KeyPress) -> Bool {
        let state = MacShortcutPreferences.shared.snapshot
        if !state.overrides.isEmpty, let value = state.overrides[id] {
            guard let chord = MacKeyChord(notation: value) else { return false }
            return MacKeyChord(KeyboardShortcut(press.key, modifiers: press.modifiers)) == chord
                || (NSApp.currentEvent.flatMap { event in
                    guard event.type == .keyDown else { return nil as MacKeyChord? }
                    return MacKeyChord(event: MacShortcutEvent(event))
                } == chord)
        }
        return press.key == definition.key
    }

    static func focus(_ direction: PaneFocusDirection) -> Self {
        switch direction {
        case .left: .focusLeft
        case .right: .focusRight
        case .up: .focusUp
        case .down: .focusDown
        }
    }
}

extension EventModifiers {
    init(shortcutFlags flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }

    var shortcutFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// Read the key once before testing the commands of a focused responder. Named keys remain usable
/// on input sources with another script and on keyboards that send Enter from the numeric keypad.
struct MacShortcutEvent {
    let flags: NSEvent.ModifierFlags
    let keyCode: UInt16
    let character: String?
    let unmodified: String?

    init(flags: NSEvent.ModifierFlags, keyCode: UInt16, character: String?, unmodified: String?) {
        self.flags = flags
        self.keyCode = keyCode
        self.character = character
        self.unmodified = unmodified
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let text = event.charactersIgnoringModifiers
        self.init(flags: flags, keyCode: event.keyCode,
                  character: flags.contains(.command) ? event.commandShortcutKey : text?.lowercased(), unmodified: text)
    }
}

extension MacShortcut {
    /// The original browser responder accepts extra modifiers for editing and navigation. Its
    /// tab-number keys and Control-Tab have always required the narrower masks below.
    func matches(_ event: MacShortcutEvent, in preferences: MacShortcutPreferences = .shared) -> Bool {
        let state = preferences.snapshot
        if !state.system.isEmpty, state.system.contains(where: { $0.chord.matches(event) }) {
            return false // Let the system's menu item take its key.
        }
        if !state.overrides.isEmpty, let value = state.overrides[id] {
            guard let chord = MacKeyChord(notation: value) else { return false }
            return chord.matches(event)
        }
        return matchesDefault(event)
    }

    func matchesDefault(_ event: MacShortcutEvent) -> Bool {
        if case let .browserTab(number) = self {
            return event.flags.subtracting(.numericPad) == .command && Int(event.character ?? "") == number
        }
        let item = definition
        let key = String(item.key.character)
        let flags = event.flags
        let required = item.modifiers.shortcutFlags
        switch self {
        case .browserNext, .browserPrevious:
            return event.keyCode == 48 && flags == required
        case .browserNew, .browserReopen, .browserClose, .browserUndo, .browserRedo:
            return flags.contains(.command) && flags.contains(.shift) == required.contains(.shift) && event.character == key
        case .browserZoomIn, .browserZoomOut, .browserReset, .browserBack, .browserForward,
             .browserReload, .browserFind, .browserAddress, .browserCopy, .browserCut, .browserPaste, .browserSelectAll:
            return flags.contains(.command) && (event.character == key || (self == .browserZoomIn && event.character == "+"))
        case .terminalAlternate:
            return flags.subtracting([.function, .numericPad, .capsLock]) == required &&
                (event.keyCode == 50 || event.unmodified == key)
        case .leaveBash:
            return flags.subtracting([.function, .numericPad, .capsLock]) == required && event.keyCode == 51
        case .browserEscape, .cancelDrag:
            return event.keyCode == 53
        case .attachSelection:
            return flags == required && event.character == key
        case .imageZoomIn, .imageZoomOut, .imageFit:
            return flags.intersection([.command, .control, .option]) == required &&
                (event.character == key || (self == .imageZoomIn && event.character == "+"))
        case .imageClose, .imagePrevious, .imageNext:
            return flags.intersection([.command, .control, .option]).isEmpty &&
                event.keyCode == (self == .imageClose ? 53 : self == .imagePrevious ? 123 : 124)
        default:
            return flags.subtracting([.function, .numericPad, .capsLock]) == required && event.character == key
        }
    }

    @MainActor static func numberedOption(_ press: KeyPress, command: (Int) -> Self, requiresPlain: Bool) -> Int? {
        let state = MacShortcutPreferences.shared.snapshot
        if !state.overrides.isEmpty {
            for number in 1...9 {
                let item = command(number)
                if state.overrides[item.id] != nil && item.matches(press) { return number }
            }
        }
        guard !requiresPlain || press.modifiers.isEmpty, let number = Int(press.characters), (1...9).contains(number),
              state.overrides.isEmpty || state.overrides[command(number).id] == nil else { return nil }
        return number
    }

    static let browserPageCommands: [Self] = [.browserNext, .browserPrevious] + (1...9).map(Self.browserTab) + [
        .browserNew, .browserReopen, .browserClose, .browserCopy, .browserCut, .browserPaste, .browserSelectAll,
        .browserUndo, .browserRedo, .browserZoomIn, .browserZoomOut, .browserReset, .browserFind,
        .browserAddress, .browserReload, .browserBack, .browserForward
    ]
}



extension View {
    /// For the original key keep SwiftUI's native key-filtered handler (including its repeat
    /// policy). A recorded chord also checks modifiers and the Command layout of the current event.
    @ViewBuilder
    func onMacKeyPress(_ command: MacShortcut, phases: KeyPress.Phases = [.down, .repeat],
                       perform: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        let state = MacShortcutPreferences.shared.snapshot
        if let value = state.overrides[command.id] {
            if !value.isEmpty {
                onKeyPress(phases: phases) { press in
                    guard command.matches(press), !ComposerFieldEditor.hasMarkedText else { return .ignored }
                    return perform(press)
                }
            } else { self }
        } else {
            onKeyPress(command.definition.key, phases: phases, action: perform)
        }
    }

    @ViewBuilder
    func onMacKeyPress(_ command: MacShortcut, perform: @escaping () -> KeyPress.Result) -> some View {
        if command.isCustomized { onMacKeyPress(command) { _ in perform() } }
        else { onKeyPress(command.definition.key, action: perform) }
    }

    /// Nil leaves the key to the views around this one, without changing this view's identity.
    @ViewBuilder
    func onMacShortcutExit(_ command: MacShortcut = .dismiss, perform: (() -> Void)?) -> some View {
        if MacShortcutPreferences.shared.snapshot.overrides[command.id] == nil {
            onExitCommand(perform: perform)
        } else {
            onMacKeyPress(command, phases: .down) { _ in
                guard let perform else { return .ignored }
                perform()
                return .handled
            }
        }
    }

    @ViewBuilder
    func onMacShortcutSubmit(_ command: MacShortcut, perform: @escaping () -> Void) -> some View {
        if MacShortcutPreferences.shared.snapshot.overrides[command.id] == nil {
            onSubmit(perform)
        } else {
            onMacKeyPress(command, phases: .down) { _ in perform(); return .handled }
        }
    }
}
