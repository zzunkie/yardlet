import SwiftUI

/// A button's tooltip with the key that does the same from the menu bar, as both apps' tooltips put
/// it after the label (the Codex app's tooltip `shortcut`, drawn as a key after the content; the Claude
/// app's tooltip `content` and `shortcut`). Plain-text tooltips write it in the parentheses Yardlet's
/// other tooltips use. Buttons pass the menu's own `KeyboardShortcut`, so the tooltip follows the key.
enum ShortcutHelp {
    static func text(_ title: String, _ shortcut: KeyboardShortcut?) -> String {
        text(title, shortcut.map { [$0] } ?? [])
    }

    /// The same with each key that does it, in the order given.
    static func text(_ title: String, _ shortcuts: [KeyboardShortcut]) -> String {
        guard !shortcuts.isEmpty else { return title }
        return "\(title) (\(shortcuts.map(\.displayText).joined(separator: ", ")))"
    }
}

extension KeyboardShortcut {
    /// The key as a menu item shows it, which is how both apps write it on a Mac: ⌃⌥⇧⌘, then the key.
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyText(key.character)
    }

    private static func keyText(_ key: Character) -> String {
        switch key {
        // ⇧Tab arrives as the back-tab character (`TabCommandShortcut.previousTab`).
        case "\t", "\u{19}": "⇥"
        case "\r": "↩"
        case "\u{1B}": "⎋"
        case "\u{08}", "\u{7F}": "⌫"
        case " ": "Space"
        case "\u{F700}": "↑"
        case "\u{F701}": "↓"
        case "\u{F702}": "←"
        case "\u{F703}": "→"
        default: String(key).uppercased()
        }
    }
}
