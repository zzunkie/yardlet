import AppKit

extension NSEvent {
    /// The key a ⌘ shortcut names, lowercased, as the menu bar reads it under any input source: what the key types
    /// with ⌘ held, in the keyboard layout in use. `charactersIgnoringModifiers` is the layout's letter without ⌘,
    /// which a layout for another script gives in that script (2-Set Korean types ㅍ on the V key, and v with ⌘), and
    /// Dvorak – QWERTY ⌘ gives Dvorak's letter where ⌘ uses QWERTY's. Shift, Option and Control do not change it;
    /// callers check the modifiers they take.
    var commandShortcutKey: String? {
        guard type == .keyDown || type == .keyUp else { return nil }
        if let key = characters(byApplyingModifiers: .command), !key.isEmpty { return key.lowercased() }
        return charactersIgnoringModifiers?.lowercased()
    }
}
