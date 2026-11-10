import Foundation

/// Key names an agent writes ("Enter", "Shift+Tab", "Meta+a") as CDP `Input.dispatchKeyEvent`
/// parameters for a US keyboard layout.
struct BrowserAgentKeyPress: Equatable {
    struct Key: Equatable {
        var key: String
        var code: String
        var keyCode: Int
        var text: String?
        var location = 0
    }

    enum Modifier: String, CaseIterable {
        case alt = "Alt", control = "Control", meta = "Meta", shift = "Shift"

        /// CDP modifier bits.
        var bit: Int {
            switch self {
            case .alt: 1
            case .control: 2
            case .meta: 4
            case .shift: 8
            }
        }

        var key: Key {
            switch self {
            case .alt: Key(key: "Alt", code: "AltLeft", keyCode: 18, location: 1)
            case .control: Key(key: "Control", code: "ControlLeft", keyCode: 17, location: 1)
            case .meta: Key(key: "Meta", code: "MetaLeft", keyCode: 91, location: 1)
            case .shift: Key(key: "Shift", code: "ShiftLeft", keyCode: 16, location: 1)
            }
        }
    }

    var key: Key
    var modifiers: [Modifier]

    var modifierBits: Int { modifiers.reduce(0) { $0 | $1.bit } }

    /// The key puts text into a field: a character (Enter's line break aside), or a paste.
    var insertsText: Bool {
        key.text.map { $0 != "\r" } ?? false || macEditingCommands.contains { $0.hasPrefix("paste") }
    }

    private static let aliases: [String: String] = [
        "Esc": "Escape", "Return": "Enter", "Up": "ArrowUp", "Down": "ArrowDown", "Left": "ArrowLeft",
        "Right": "ArrowRight", "Del": "Delete", "Spacebar": "Space"
    ]
    private static let modifierNames: [String: Modifier] = [
        "alt": .alt, "option": .alt, "control": .control, "ctrl": .control, "meta": .meta, "command": .meta,
        "cmd": .meta, "shift": .shift
    ]
    private static let named: [String: Key] = {
        var keys: [String: Key] = [
            "Enter": Key(key: "Enter", code: "Enter", keyCode: 13, text: "\r"),
            "Tab": Key(key: "Tab", code: "Tab", keyCode: 9),
            "Escape": Key(key: "Escape", code: "Escape", keyCode: 27),
            "Backspace": Key(key: "Backspace", code: "Backspace", keyCode: 8),
            "Delete": Key(key: "Delete", code: "Delete", keyCode: 46),
            "Insert": Key(key: "Insert", code: "Insert", keyCode: 45),
            "Home": Key(key: "Home", code: "Home", keyCode: 36),
            "End": Key(key: "End", code: "End", keyCode: 35),
            "PageUp": Key(key: "PageUp", code: "PageUp", keyCode: 33),
            "PageDown": Key(key: "PageDown", code: "PageDown", keyCode: 34),
            "ArrowLeft": Key(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37),
            "ArrowUp": Key(key: "ArrowUp", code: "ArrowUp", keyCode: 38),
            "ArrowRight": Key(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
            "ArrowDown": Key(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
            "Space": Key(key: " ", code: "Space", keyCode: 32, text: " ")
        ]
        for number in 1...12 {
            keys["F\(number)"] = Key(key: "F\(number)", code: "F\(number)", keyCode: 111 + number)
        }
        return keys
    }()
    /// US-layout punctuation: character → (code, key code, shifted).
    private static let punctuation: [Character: (String, Int, Bool)] = [
        "-": ("Minus", 189, false), "_": ("Minus", 189, true), "=": ("Equal", 187, false), "+": ("Equal", 187, true),
        "[": ("BracketLeft", 219, false), "{": ("BracketLeft", 219, true), "]": ("BracketRight", 221, false),
        "}": ("BracketRight", 221, true), "\\": ("Backslash", 220, false), "|": ("Backslash", 220, true),
        ";": ("Semicolon", 186, false), ":": ("Semicolon", 186, true), "'": ("Quote", 222, false),
        "\"": ("Quote", 222, true), ",": ("Comma", 188, false), "<": ("Comma", 188, true),
        ".": ("Period", 190, false), ">": ("Period", 190, true), "/": ("Slash", 191, false), "?": ("Slash", 191, true),
        "`": ("Backquote", 192, false), "~": ("Backquote", 192, true), "!": ("Digit1", 49, true),
        "@": ("Digit2", 50, true), "#": ("Digit3", 51, true), "$": ("Digit4", 52, true), "%": ("Digit5", 53, true),
        "^": ("Digit6", 54, true), "&": ("Digit7", 55, true), "*": ("Digit8", 56, true), "(": ("Digit9", 57, true),
        ")": ("Digit0", 48, true)
    ]

    /// Parses "Shift+Tab", "Meta+a", "Enter", or one character.
    static func parse(_ text: String) -> BrowserAgentKeyPress? {
        guard !text.isEmpty else { return nil }
        var parts = text.count > 1 && text.hasSuffix("++")
            ? text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init) + ["+"]
            : text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if text == "+" { parts = ["+"] }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        var modifiers: [Modifier] = []
        for part in parts {
            let name = part.lowercased() == "controlormeta" ? "meta" : part.lowercased()
            guard let modifier = modifierNames[name] else { return nil }
            if !modifiers.contains(modifier) { modifiers.append(modifier) }
        }
        guard var key = self.key(named: keyName) else { return nil }
        let shifted = modifiers.contains(.shift)
        if shifted, key.key.count == 1, let letter = key.key.first, letter.isLetter {
            key.key = key.key.uppercased()
            key.text = key.key
        }
        // A shortcut produces no text.
        if modifiers.contains(where: { $0 != .shift }) { key.text = nil }
        return BrowserAgentKeyPress(key: key, modifiers: modifiers.sorted { $0.bit < $1.bit })
    }

    private static func key(named rawName: String) -> Key? {
        let name = aliases[rawName] ?? rawName
        if let key = named[name] { return key }
        if let key = named.first(where: { $0.key.lowercased() == name.lowercased() })?.value { return key }
        guard name.count == 1, let character = name.first else { return nil }
        if character.isASCII, character.isLetter {
            let upper = Int(character.uppercased().unicodeScalars.first!.value)
            return Key(key: String(character), code: "Key\(character.uppercased())", keyCode: upper, text: String(character))
        }
        if character.isASCII, let digit = character.wholeNumberValue {
            return Key(key: String(character), code: "Digit\(digit)", keyCode: 48 + digit, text: String(character))
        }
        if let (code, keyCode, _) = punctuation[character] {
            return Key(key: String(character), code: code, keyCode: keyCode, text: String(character))
        }
        return Key(key: String(character), code: "", keyCode: 0, text: String(character))
    }

    /// The `Input.dispatchKeyEvent` parameters that press the key: each modifier down, the key down and up, then the
    /// modifiers up. With `macEditingCommands` the key down carries the editing commands Chromium on macOS needs.
    func keyEvents(macEditingCommands: Bool) -> [[String: JSONValue]] {
        var events: [[String: JSONValue]] = []
        var held = 0
        for modifier in modifiers {
            held |= modifier.bit
            events.append(Self.keyEvent("rawKeyDown", modifier.key, modifiers: held))
        }
        var down = Self.keyEvent(key.text == nil ? "rawKeyDown" : "keyDown", key, modifiers: held)
        if macEditingCommands, !self.macEditingCommands.isEmpty {
            down["commands"] = .array(self.macEditingCommands.map { .string($0) })
        }
        events.append(down)
        events.append(Self.keyEvent("keyUp", key, modifiers: held))
        for modifier in modifiers.reversed() {
            held &= ~modifier.bit
            events.append(Self.keyEvent("keyUp", modifier.key, modifiers: held))
        }
        return events
    }

    private static func keyEvent(_ type: String, _ key: Key, modifiers: Int) -> [String: JSONValue] {
        var event: [String: JSONValue] = [
            "type": .string(type), "key": .string(key.key), "code": .string(key.code),
            "windowsVirtualKeyCode": .integer(Int64(key.keyCode)), "modifiers": .integer(Int64(modifiers))
        ]
        if key.location != 0 { event["location"] = .integer(Int64(key.location)) }
        if type == "keyDown", let text = key.text {
            event["text"] = .string(text)
            event["unmodifiedText"] = .string(text)
        }
        return event
    }

    /// Chromium on macOS performs editing keys only through these commands, which a native key
    /// event gets from the text input system and a CDP key event has to carry itself.
    var macEditingCommands: [String] {
        let shortcut = (modifiers.sorted { Self.order($0) < Self.order($1) }.map(\.rawValue) + [key.code])
            .joined(separator: "+")
        return Self.macCommands[shortcut] ?? []
    }

    private static func order(_ modifier: Modifier) -> Int {
        [.shift, .control, .alt, .meta].firstIndex(of: modifier) ?? 0
    }

    private static let macCommands: [String: [String]] = [
        "Backspace": ["deleteBackward"],
        "Delete": ["deleteForward"],
        "Alt+Backspace": ["deleteWordBackward"],
        "Meta+Backspace": ["deleteToBeginningOfLine"],
        "ArrowLeft": ["moveLeft"],
        "ArrowRight": ["moveRight"],
        "ArrowUp": ["moveUp"],
        "ArrowDown": ["moveDown"],
        "Shift+ArrowLeft": ["moveLeftAndModifySelection"],
        "Shift+ArrowRight": ["moveRightAndModifySelection"],
        "Shift+ArrowUp": ["moveUpAndModifySelection"],
        "Shift+ArrowDown": ["moveDownAndModifySelection"],
        "Alt+ArrowLeft": ["moveWordLeft"],
        "Alt+ArrowRight": ["moveWordRight"],
        "Meta+ArrowLeft": ["moveToLeftEndOfLine"],
        "Meta+ArrowRight": ["moveToRightEndOfLine"],
        "Meta+ArrowUp": ["moveToBeginningOfDocument"],
        "Meta+ArrowDown": ["moveToEndOfDocument"],
        "Home": ["scrollToBeginningOfDocument"],
        "End": ["scrollToEndOfDocument"],
        "PageUp": ["scrollPageUp"],
        "PageDown": ["scrollPageDown"],
        "Meta+KeyA": ["selectAll"],
        "Meta+KeyC": ["copy"],
        "Meta+KeyX": ["cut"],
        "Meta+KeyV": ["paste"],
        "Meta+KeyZ": ["undo"],
        "Shift+Meta+KeyZ": ["redo"]
    ]
}
