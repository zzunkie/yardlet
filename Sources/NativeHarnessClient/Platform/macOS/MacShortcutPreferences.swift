import AppKit
import Carbon.HIToolbox
import Observation
import os
import SwiftUI

/// The preferences dictionary uses the Mac key-binding notation. An empty value clears the key;
/// an absent entry follows the command's default, including the current composer send preference.
struct MacKeyChord: Equatable, Sendable {
    let key: String
    let modifiers: SwiftUI.EventModifiers

    init(_ shortcut: KeyboardShortcut) {
        self.init(String(shortcut.key.character), shortcut.modifiers)
    }

    init(_ key: String, _ modifiers: SwiftUI.EventModifiers) {
        self.key = key == "\u{19}" ? "\t" : key
        self.modifiers = modifiers.intersection([.command, .shift, .control, .option])
    }

    init?(notation: String) {
        guard let last = notation.last else { return nil }
        var modifiers: SwiftUI.EventModifiers = []
        for modifier in notation.dropLast() {
            switch modifier {
            case "^": modifiers.insert(.control)
            case "~": modifiers.insert(.option)
            case "$": modifiers.insert(.shift)
            case "@": modifiers.insert(.command)
            default: return nil
            }
        }
        if last.isUppercase || last == "\u{19}" { modifiers.insert(.shift) }
        self.init(last.lowercased(), modifiers)
    }

    init?(event: MacShortcutEvent) {
        let key: String?
        switch event.keyCode {
        case 36, 76: key = "\r"
        case 48: key = "\t"
        case 51: key = "\u{7f}"
        case 53: key = "\u{1b}"
        default: key = event.character
        }
        guard let key, key.count == 1 else { return nil }
        self.init(key, SwiftUI.EventModifiers(shortcutFlags: event.flags))
    }

    /// A menu may name a shifted punctuation mark directly (⌘?), while the recorder sees the
    /// underlying key and Shift. Use what this particular layout produced.
    static func shiftedEquivalent(of event: MacShortcutEvent) -> Self? {
        guard event.flags.contains(.shift), let text = event.unmodified, text.count == 1,
              let character = text.first, character.isPunctuation || character.isSymbol,
              text != event.character else { return nil }
        return Self(text, SwiftUI.EventModifiers(shortcutFlags: event.flags).subtracting(.shift))
    }

    func matches(_ event: MacShortcutEvent) -> Bool {
        self == Self(event: event) || self == Self.shiftedEquivalent(of: event)
    }

    var notation: String {
        var text = ""
        if modifiers.contains(.control) { text += "^" }
        if modifiers.contains(.option) { text += "~" }
        if modifiers.contains(.shift) { text += "$" }
        if modifiers.contains(.command) { text += "@" }
        return text + key
    }

    var binding: KeyboardShortcut {
        let character = key == "\t" && modifiers.contains(.shift) ? "\u{19}" : key
        return KeyboardShortcut(KeyEquivalent(Character(character)), modifiers: modifiers)
    }

    var displayText: String { binding.displayText }

    var event: MacShortcutEvent {
        let code: UInt16
        switch key {
        case "\t": code = 48
        case "\r": code = 36
        case "\u{1b}": code = 53
        case "\u{7f}": code = 51
        case "\u{f702}": code = 123
        case "\u{f703}": code = 124
        default: code = .max
        }
        return MacShortcutEvent(flags: modifiers.shortcutFlags, keyCode: code, character: key, unmodified: key)
    }

    var systemUse: String? {
        switch (key, modifiers) {
        case (" ", .command): L10n.string("Spotlight")
        case (" ", .control), (" ", [.control, .option]): L10n.string("Input source switching")
        case ("\t", .command), ("\t", [.command, .shift]): L10n.string("App switching")
        default: nil
        }
    }
}

/// These system bindings are physical keys. Look them up only when recording a shortcut; the API
/// does not supply the name of the individual system feature.
@MainActor
func isMacSystemHotKey(_ event: MacShortcutEvent) -> Bool {
    var result: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&result) == noErr, let values = result?.takeRetainedValue() as? [[String: Any]] else {
        return false
    }
    var mask = 0
    if event.flags.contains(.command) { mask |= cmdKey }
    if event.flags.contains(.option) { mask |= optionKey }
    if event.flags.contains(.shift) { mask |= shiftKey }
    if event.flags.contains(.control) { mask |= controlKey }
    return values.contains {
        $0[kHISymbolicHotKeyEnabled] as? Bool == true &&
        $0[kHISymbolicHotKeyCode] as? Int == Int(event.keyCode) && $0[kHISymbolicHotKeyModifiers] as? Int == mask
    }
}

struct MacMenuAssignment: Equatable, Sendable {
    var name: String
    var chord: MacKeyChord
    var commands: Set<MacShortcut>
}

extension MacShortcut {
    func additionalDefaults(send: SendShortcut) -> [MacKeyChord] {
        switch self {
        case .composerSend where send == .commandReturnForMultiline,
             .composerNewline where send != .return:
            [MacKeyChord("\r", [])]
        case .browserZoomIn, .imageZoomIn:
            [MacKeyChord("+", .command)]
        case .zoomIn:
            [MacKeyChord("=", .command)]
        default: []
        }
    }

    /// A menu item can have different titles depending on the window. macOS stores its visible
    /// title (optionally qualified by a menu path), rather than Yardlet's command identifier.
    fileprivate var menuTitles: [String] {
        switch self {
        case .settings: ["Settings…"]
        case .palette: ["Search tasks and commands"]
        case .toggleSidebar: ["Show sidebar", "Hide sidebar"]
        case .toggleSessionRail: ["Show session rail", "Hide session rail"]
        case .toggleSidePanel: ["Show side panel", "Hide side panel"]
        case .toggleTerminal: ["Show terminal", "Hide terminal"]
        case .toggleActivityView: ["View activity", "Turn off activity view"]
        case .togglePinned: ["Pin task", "Unpin task", "Pin split view", "Unpin split view"]
        case .closeTab: ["Close Tab", "Close"]
        case .maximizePane: ["Maximize pane", "Restore split view"]
        case .nextTab: ["Show Next Tab", "Next task"]
        case .previousTab: ["Show Previous Tab", "Previous task"]
        case .help, .newTask, .previousTask, .nextTask, .nextTaskNeedingAttention, .markUnread, .archive,
             .openModelMenu, .back, .forward, .newTab, .closeWindow, .reopenClosedTab, .splitRight, .splitDown,
             .closePane, .focusLeft, .focusRight, .focusUp, .focusDown, .conversationFind, .nextResult, .previousResult,
             .actualSize, .zoomIn, .zoomOut:
            [definition.title]
        default: []
        }
    }
}

@Observable
final class MacShortcutPreferences: Sendable {
    static let key = "YardletMacKeyboardShortcuts"
    static let shared = MacShortcutPreferences(defaults: .yardlet)

    struct Snapshot: Equatable, Sendable {
        var overrides: [String: String]
        var system: [MacMenuAssignment] = []
        var nativeMenu: [MacMenuAssignment] = []
    }

    // SwiftUI reads bindings in menu and view bodies. AppKit also reads them synchronously in the
    // focused responder; neither path reads or decodes preferences for each key.
    private let state: OSAllocatedUnfairLock<Snapshot>
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        state = OSAllocatedUnfairLock(initialState: Snapshot(overrides: saved))
    }

    var snapshot: Snapshot {
        access(keyPath: \.snapshot)
        return state.withLock { $0 }
    }

    func binding(for command: MacShortcut, send: SendShortcut = .return) -> KeyboardShortcut? {
        let current = snapshot
        if let assignment = current.system.first(where: { $0.commands.contains(command) }) {
            return assignment.chord.binding
        }
        let binding: KeyboardShortcut?
        if !current.overrides.isEmpty, let value = current.overrides[command.id] {
            binding = MacKeyChord(notation: value)?.binding
        } else { binding = command.defaultBinding(send: send) }
        if !current.system.isEmpty, let binding, current.system.contains(where: { $0.chord == MacKeyChord(binding) }) {
            return nil
        }
        return binding
    }

    func displayedKeys(for command: MacShortcut, send: SendShortcut) -> String? {
        guard let binding = binding(for: command, send: send) else { return nil }
        return ([binding.displayText] + additionalKeys(for: command, send: send).map(\.displayText)).joined(separator: " / ")
    }

    /// The keys a command takes beside its binding (`MacShortcut.additionalDefaults`) while it keeps its default: none
    /// once the person or macOS App Shortcuts gave it a key, and none that App Shortcuts gave another command.
    func additionalKeys(for command: MacShortcut, send: SendShortcut) -> [MacKeyChord] {
        let current = snapshot
        guard current.overrides[command.id] == nil, !current.system.contains(where: { $0.commands.contains(command) }) else {
            return []
        }
        return command.additionalDefaults(send: send).filter { chord in !current.system.contains { $0.chord == chord } }
    }

    @MainActor
    func readSystemAssignments(pinned: @autoclosure () -> [String] = [], menu: NSMenu? = nil) {
        let pinned = pinned()
        let names = Self.menuCommands(pinned: pinned)
        let items = menu.map(Self.nativeMenuItems) ?? []
        let effective = defaults.dictionary(forKey: "NSUserKeyEquivalents") as? [String: String] ?? [:]
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] as? [String: String] ?? [:]
        // An all-applications assignment for a title that only another app owns takes no key here.
        let menuNames = Set(items.map(\.name)).union(names.keys)
        var raw = global.filter { menuNames.contains(Self.menuPath($0.key).last ?? "") }
        if effective != global { raw.merge(effective) { _, local in local } }
        let assigned = Self.assignments(from: raw, names: names)
        let native = items.filter { !names.keys.contains($0.name) && !$0.chord.key.isEmpty }
        setSystemAssignments(assigned, nativeMenu: native)
    }

    @MainActor private static func nativeMenuItems(_ menu: NSMenu) -> [MacMenuAssignment] {
        menu.items.flatMap { item -> [MacMenuAssignment] in
            if let nested = item.submenu { return nativeMenuItems(nested) }
            let key = item.keyEquivalent
            guard key.count == 1 else { return [] }
            var flags = SwiftUI.EventModifiers(shortcutFlags: item.keyEquivalentModifierMask)
            if key.first?.isUppercase == true { flags.insert(.shift) }
            return [MacMenuAssignment(name: item.title, chord: MacKeyChord(key.lowercased(), flags), commands: [])]
        }
    }

    private static func menuPath(_ path: String) -> [String] {
        path.replacingOccurrences(of: "->", with: "\u{1b}").split(separator: "\u{1b}").map(String.init)
    }

    private static func menuCommands(pinned: [String]) -> [String: Set<MacShortcut>] {
        var names: [String: Set<MacShortcut>] = [:]
        for command in MacShortcut.all {
            for title in command.menuTitles {
                names[L10n.string(title), default: []].insert(command)
            }
        }
        for (index, title) in pinned.prefix(9).enumerated() {
            names[title, default: []].insert(.pinnedRow(index + 1))
        }
        return names
    }

    private static func assignments(from raw: [String: String], names: [String: Set<MacShortcut>]) -> [MacMenuAssignment] {
        raw.keys.sorted().compactMap { path in
            let components = menuPath(path)
            guard let name = components.last, let value = raw[path],
                  let chord = MacKeyChord(notation: value) else { return nil }
            var commands = names[name] ?? []
            if components.count > 1 {
                let parent = String(components[components.count - 2])
                if parent == L10n.string("Task") { commands.subtract([.nextTab, .previousTab]) }
                if parent == L10n.string("Window") { commands.subtract([.nextTask, .previousTask]) }
            }
            return MacMenuAssignment(name: name, chord: chord, commands: commands)
        }
    }

    @MainActor
    func setSystemAssignments(_ assignments: [MacMenuAssignment], nativeMenu: [MacMenuAssignment] = []) {
        var next = snapshot
        next.system = assignments
        next.nativeMenu = nativeMenu
        for command in assignments.flatMap(\.commands) { next.overrides.removeValue(forKey: command.id) }
        update(next)
    }

    enum Proposal: Equatable {
        case ready
        case conflicts([MacShortcut])
        case refused(String)
    }

    @MainActor
    func proposal(_ chord: MacKeyChord?, for command: MacShortcut, send: SendShortcut,
                  equivalent: MacKeyChord? = nil) -> Proposal {
        let current = snapshot
        if let assignment = current.system.first(where: { $0.commands.contains(command) ||
            (chord != nil && ($0.chord == chord || $0.chord == equivalent)) }) {
            return .refused(L10n.format("%@ is assigned to %@ in macOS App Shortcuts.", assignment.chord.displayText, assignment.name))
        }
        guard let chord else { return .ready }
        if let system = chord.systemUse { return .refused(L10n.format("macOS uses %@ for %@.", chord.displayText, system)) }
        let ownDefault = MacKeyChord(command.defaultBinding(send: send))
        if chord != ownDefault, let item = current.nativeMenu.first(where: { $0.chord == chord || $0.chord == equivalent }) {
            return .refused(L10n.format("The macOS menu command %@ uses %@.", item.name, chord.displayText))
        }
        let conflicts = MacShortcut.all.filter { other in
            guard other != command, let binding = binding(for: other, send: send) else { return false }
            // Restoring a shared factory binding preserves its established focus and precedence.
            if (chord == ownDefault || equivalent == ownDefault) && current.overrides[other.id] == nil { return false }
            if MacKeyChord(binding) == chord || MacKeyChord(binding) == equivalent { return true }
            guard current.overrides[other.id] == nil else { return false }
            if other.additionalDefaults(send: send).contains(chord) { return true }
            switch other {
            case .browserNew, .browserClose, .browserReopen, .browserNext, .browserPrevious, .browserCopy,
                 .browserCut, .browserPaste, .browserSelectAll, .browserUndo, .browserRedo, .browserZoomIn,
                 .browserZoomOut, .browserReset, .browserFind, .browserAddress, .browserReload, .browserBack,
                 .browserForward, .browserTab, .browserEscape, .imageZoomIn, .imageZoomOut, .imageFit,
                 .imageClose, .imagePrevious, .imageNext, .terminalAlternate, .cancelDrag:
                return other.matchesDefault(chord.event)
            default: return false
            }
        }
        return conflicts.isEmpty ? .ready : .conflicts(conflicts)
    }

    /// Recheck before committing. A sheet opened in another window may have changed either key.
    @MainActor @discardableResult
    func assign(_ chord: MacKeyChord?, to command: MacShortcut, send: SendShortcut,
                replacing confirmed: [MacShortcut] = [], equivalent: MacKeyChord? = nil) -> Proposal {
        let result = proposal(chord, for: command, send: send, equivalent: equivalent)
        let conflicts: [MacShortcut]
        switch result {
        case .ready: conflicts = []
        case let .conflicts(actual) where Set(actual) == Set(confirmed): conflicts = actual
        default: return result
        }
        var next = snapshot
        for other in conflicts { next.overrides[other.id] = "" }
        let standard = MacKeyChord(command.defaultBinding(send: send))
        next.overrides[command.id] = (chord == standard || equivalent == standard) ? nil : chord?.notation ?? ""
        update(next)
        return .ready
    }

    @MainActor
    func restoreAll() {
        var next = snapshot
        next.overrides.removeAll()
        update(next)
    }

    @MainActor private func update(_ next: Snapshot) {
        let previous = snapshot
        guard next != previous else { return }
        if next.overrides != previous.overrides {
            if next.overrides.isEmpty { defaults.removeObject(forKey: Self.key) }
            else { defaults.set(next.overrides, forKey: Self.key) }
        }
        withMutation(keyPath: \.snapshot) { state.withLock { $0 = next } }
    }
}
