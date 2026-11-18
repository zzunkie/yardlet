import YardletSimulatorHostProtocol

/// The person's keys on an Android device's screen as Android key events. The screen view sends every device a key
/// by its place on the keyboard, as a HID keyboard usage (`SimulatorKeyMap`); here it becomes Android's key code, so
/// the device's own keyboard layout makes the character, as with a hardware keyboard plugged into the device.
/// Android reads Shift and the other modifiers from each key event's meta state, so the keyboard keeps which ones
/// are held, and whether Caps Lock is on.
struct AndroidKeyboard {
    private var held: Set<UInt32> = []
    private var capsLock = false

    /// The key events for a key going down, up, or both (Caps Lock, pressed once at each change); none for a key
    /// Android has no code for.
    mutating func messages(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase) -> [ScrcpyControlMessage] {
        guard let keycode = Self.keycodes[usage.rawValue] else { return [] }
        // A modifier's own events carry it while it is down, as a hardware keyboard's do.
        switch phase {
        case .down:
            if Self.modifiers[usage.rawValue] != nil { held.insert(usage.rawValue) }
            return [.key(.down, keycode: keycode, metaState: metaState)]
        case .up:
            held.remove(usage.rawValue)
            return [.key(.up, keycode: keycode, metaState: metaState)]
        case .press:
            if usage.rawValue == Self.capsLockUsage { capsLock.toggle() }
            return [.key(.down, keycode: keycode, metaState: metaState), .key(.up, keycode: keycode, metaState: metaState)]
        }
    }

    /// `KeyEvent.META_*` for the modifiers held: each one's bit for either side and its side's bit.
    var metaState: UInt32 {
        held.reduce(capsLock ? 0x10_0000 : 0) { $0 | (Self.modifiers[$1] ?? 0) }
    }

    private static let capsLockUsage: UInt32 = 0x39

    /// Left and right Control, Shift, Option (Alt) and Command (Meta).
    private static let modifiers: [UInt32: UInt32] = [
        0xE0: 0x1000 | 0x2000, 0xE4: 0x1000 | 0x4000,
        0xE1: 0x1 | 0x40, 0xE5: 0x1 | 0x80,
        0xE2: 0x2 | 0x10, 0xE6: 0x2 | 0x20,
        0xE3: 0x1_0000 | 0x2_0000, 0xE7: 0x1_0000 | 0x4_0000
    ]

    /// HID keyboard usages (page 0x07) to `KeyEvent.KEYCODE_*`.
    private static let keycodes: [UInt32: UInt32] = [
        // Letters: KEYCODE_A (29) to KEYCODE_Z (54).
        0x04: 29, 0x05: 30, 0x06: 31, 0x07: 32, 0x08: 33, 0x09: 34, 0x0A: 35, 0x0B: 36, 0x0C: 37, 0x0D: 38,
        0x0E: 39, 0x0F: 40, 0x10: 41, 0x11: 42, 0x12: 43, 0x13: 44, 0x14: 45, 0x15: 46, 0x16: 47, 0x17: 48,
        0x18: 49, 0x19: 50, 0x1A: 51, 0x1B: 52, 0x1C: 53, 0x1D: 54,
        // Digits 1 to 9 and 0: KEYCODE_1 (8) to KEYCODE_9 (16), KEYCODE_0 (7).
        0x1E: 8, 0x1F: 9, 0x20: 10, 0x21: 11, 0x22: 12, 0x23: 13, 0x24: 14, 0x25: 15, 0x26: 16, 0x27: 7,
        // Return, Escape, Delete (KEYCODE_DEL), Tab, Space.
        0x28: 66, 0x29: 111, 0x2A: 67, 0x2B: 61, 0x2C: 62,
        // Punctuation; the ISO key beside Shift is the grave accent's.
        0x2D: 69, 0x2E: 70, 0x2F: 71, 0x30: 72, 0x31: 73, 0x33: 74, 0x34: 75, 0x35: 68, 0x36: 55, 0x37: 56,
        0x38: 76, 0x64: 68,
        // Caps Lock and F1 to F12.
        0x39: 115, 0x3A: 131, 0x3B: 132, 0x3C: 133, 0x3D: 134, 0x3E: 135, 0x3F: 136, 0x40: 137, 0x41: 138,
        0x42: 139, 0x43: 140, 0x44: 141, 0x45: 142,
        // Insert (Help), Home, Page Up, Forward Delete, End, Page Down and the arrows.
        0x49: 124, 0x4A: 122, 0x4B: 92, 0x4C: 112, 0x4D: 123, 0x4E: 93, 0x4F: 22, 0x50: 21, 0x51: 20, 0x52: 19,
        // Keypad: Clear (where Num Lock is), the operators, Enter, the digits, the point and Equals.
        0x53: 143, 0x54: 154, 0x55: 155, 0x56: 156, 0x57: 157, 0x58: 160, 0x59: 145, 0x5A: 146, 0x5B: 147,
        0x5C: 148, 0x5D: 149, 0x5E: 150, 0x5F: 151, 0x60: 152, 0x61: 153, 0x62: 144, 0x63: 158, 0x67: 161,
        // The context menu key.
        0x65: 82,
        // Japanese keyboards: the keypad comma, Ro, Yen, Kana and Eisu.
        0x85: 159, 0x87: 217, 0x89: 216, 0x90: 218, 0x91: 212,
        // Control, Shift, Option and Command, left then right.
        0xE0: 113, 0xE1: 59, 0xE2: 57, 0xE3: 117, 0xE4: 114, 0xE5: 60, 0xE6: 58, 0xE7: 118
    ]
}
