import AppKit

/// The person's keys on an Android panel as Android key events. A Mac key goes by its place on the keyboard (its
/// virtual key code), not by the character the Mac would type, so the device's own keyboard layout makes the
/// character, as with a hardware keyboard plugged into the device.
enum AndroidKeyInput {
    /// The messages for a key event, a modifier's change included; none for a key Android has no code for.
    static func messages(for event: NSEvent) -> [ScrcpyControlMessage] {
        guard let keycode = keycode(forMacKeyCode: event.keyCode) else { return [] }
        let meta = metaState(event.modifierFlags)
        switch event.type {
        case .keyDown:
            return [.key(.down, keycode: keycode, repeatCount: event.isARepeat ? 1 : 0, metaState: meta)]
        case .keyUp:
            return [.key(.up, keycode: keycode, metaState: meta)]
        case .flagsChanged:
            // Caps Lock reports each toggle once, as a press.
            if event.keyCode == capsLock {
                return [.key(.down, keycode: keycode, metaState: meta), .key(.up, keycode: keycode, metaState: meta)]
            }
            guard let isDown = modifierIsDown(event.keyCode, event.modifierFlags) else { return [] }
            return [.key(isDown ? .down : .up, keycode: keycode, metaState: meta)]
        default:
            return []
        }
    }

    static func keycode(forMacKeyCode keyCode: UInt16) -> UInt32? { keycodes[keyCode] }

    /// Android's meta state (`KeyEvent.META_*`) for the modifiers held, each side told apart when the Mac does.
    static func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var state: UInt32 = 0
        for modifier in modifiers where flags.contains(modifier.flag) {
            state |= modifier.on
            let left = flags.rawValue & modifier.leftDevice != 0
            let right = flags.rawValue & modifier.rightDevice != 0
            if left || !right { state |= modifier.leftOn }
            if right { state |= modifier.rightOn }
        }
        if flags.contains(.capsLock) { state |= 0x10_0000 } // META_CAPS_LOCK_ON
        return state
    }

    // MARK: - Private

    private static let capsLock: UInt16 = 0x39

    /// A modifier: its flag, Android's meta bits for either side and for each side, and the Mac's device-dependent
    /// bits for each side (IOKit's NX_DEVICE*KEYMASK).
    private struct Modifier {
        var flag: NSEvent.ModifierFlags
        var on: UInt32
        var leftOn: UInt32
        var rightOn: UInt32
        var leftDevice: UInt
        var rightDevice: UInt
        var leftKey: UInt16
        var rightKey: UInt16
    }

    private static let modifiers: [Modifier] = [
        Modifier(flag: .shift, on: 0x1, leftOn: 0x40, rightOn: 0x80, leftDevice: 0x2, rightDevice: 0x4,
                 leftKey: 0x38, rightKey: 0x3C),
        Modifier(flag: .option, on: 0x2, leftOn: 0x10, rightOn: 0x20, leftDevice: 0x20, rightDevice: 0x40,
                 leftKey: 0x3A, rightKey: 0x3D),
        Modifier(flag: .control, on: 0x1000, leftOn: 0x2000, rightOn: 0x4000, leftDevice: 0x1, rightDevice: 0x2000,
                 leftKey: 0x3B, rightKey: 0x3E),
        Modifier(flag: .command, on: 0x1_0000, leftOn: 0x2_0000, rightOn: 0x4_0000, leftDevice: 0x8, rightDevice: 0x10,
                 leftKey: 0x37, rightKey: 0x36)
    ]

    /// Whether the modifier key that changed is now down: its side's device bit, or its flag when the event carries
    /// no device bits.
    private static func modifierIsDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool? {
        guard let modifier = modifiers.first(where: { $0.leftKey == keyCode || $0.rightKey == keyCode }) else {
            return nil
        }
        let device = keyCode == modifier.leftKey ? modifier.leftDevice : modifier.rightDevice
        let anySide = modifier.leftDevice | modifier.rightDevice
        if flags.rawValue & anySide == 0 { return flags.contains(modifier.flag) }
        return flags.rawValue & device != 0
    }

    /// Carbon's `kVK_*` codes to `KeyEvent.KEYCODE_*`, for the ANSI, ISO and JIS layouts.
    private static let keycodes: [UInt16: UInt32] = [
        // Letters: KEYCODE_A (29) to KEYCODE_Z (54).
        0x00: 29, 0x0B: 30, 0x08: 31, 0x02: 32, 0x0E: 33, 0x03: 34, 0x05: 35, 0x04: 36, 0x22: 37, 0x26: 38,
        0x28: 39, 0x25: 40, 0x2E: 41, 0x2D: 42, 0x1F: 43, 0x23: 44, 0x0C: 45, 0x0F: 46, 0x01: 47, 0x11: 48,
        0x20: 49, 0x09: 50, 0x0D: 51, 0x07: 52, 0x10: 53, 0x06: 54,
        // Digits: KEYCODE_0 (7) to KEYCODE_9 (16).
        0x1D: 7, 0x12: 8, 0x13: 9, 0x14: 10, 0x15: 11, 0x17: 12, 0x16: 13, 0x1A: 14, 0x1C: 15, 0x19: 16,
        // Punctuation; the ISO section key sits where the grave accent does.
        0x2B: 55, 0x2F: 56, 0x32: 68, 0x0A: 68, 0x1B: 69, 0x18: 70, 0x21: 71, 0x1E: 72, 0x2A: 73, 0x29: 74,
        0x27: 75, 0x2C: 76,
        // Return, Tab, Space, Delete (KEYCODE_DEL), Forward Delete, Escape, Help (Insert).
        0x24: 66, 0x30: 61, 0x31: 62, 0x33: 67, 0x75: 112, 0x35: 111, 0x72: 124,
        // Home, End, Page Up, Page Down and the arrows.
        0x73: 122, 0x77: 123, 0x74: 92, 0x79: 93, 0x7B: 21, 0x7C: 22, 0x7D: 20, 0x7E: 19,
        // Shift, Option, Control and Command on each side, and Caps Lock.
        0x38: 59, 0x3C: 60, 0x3A: 57, 0x3D: 58, 0x3B: 113, 0x3E: 114, 0x37: 117, 0x36: 118, 0x39: 115,
        // F1 to F12.
        0x7A: 131, 0x78: 132, 0x63: 133, 0x76: 134, 0x60: 135, 0x61: 136, 0x62: 137, 0x64: 138, 0x65: 139,
        0x6D: 140, 0x67: 141, 0x6F: 142,
        // Keypad: digits, operators, the decimal point, Enter, Equals, and Clear where Num Lock is.
        0x52: 144, 0x53: 145, 0x54: 146, 0x55: 147, 0x56: 148, 0x57: 149, 0x58: 150, 0x59: 151, 0x5B: 152,
        0x5C: 153, 0x4B: 154, 0x43: 155, 0x4E: 156, 0x45: 157, 0x41: 158, 0x4C: 160, 0x51: 161, 0x47: 143,
        // JIS: Yen, Ro, the keypad comma, Eisu and Kana.
        0x5D: 216, 0x5E: 217, 0x5F: 159, 0x66: 212, 0x68: 218
    ]
}
