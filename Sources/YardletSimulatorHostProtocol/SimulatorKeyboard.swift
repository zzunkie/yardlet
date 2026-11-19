/// Keys of a US hardware keyboard, as HID keyboard usages (page 0x07).
public enum SimulatorKeyboard {
    public static let returnKey = SimulatorKeyUsage(0x28)!
    public static let escape = SimulatorKeyUsage(0x29)!
    public static let deleteBackward = SimulatorKeyUsage(0x2A)!
    public static let tab = SimulatorKeyUsage(0x2B)!
    public static let space = SimulatorKeyUsage(0x2C)!
    public static let rightArrow = SimulatorKeyUsage(0x4F)!
    public static let leftArrow = SimulatorKeyUsage(0x50)!
    public static let downArrow = SimulatorKeyUsage(0x51)!
    public static let upArrow = SimulatorKeyUsage(0x52)!
    public static let leftControl = SimulatorKeyUsage(0xE0)!
    public static let leftShift = SimulatorKeyUsage(0xE1)!
    public static let leftCommand = SimulatorKeyUsage(0xE3)!
    public static let letterA = SimulatorKeyUsage(0x04)!
    public static let letterV = SimulatorKeyUsage(0x19)!

    /// The key that types `scalar` and whether it takes Shift; nil for anything but printable ASCII, a newline or a tab.
    public static func stroke(for scalar: Unicode.Scalar) -> (usage: SimulatorKeyUsage, shift: Bool)? {
        let value = scalar.value
        switch value {
        case 0x61...0x7A: return (SimulatorKeyUsage(0x04 + value - 0x61)!, false)  // a-z
        case 0x41...0x5A: return (SimulatorKeyUsage(0x04 + value - 0x41)!, true)  // A-Z
        case 0x31...0x39: return (SimulatorKeyUsage(0x1E + value - 0x31)!, false)  // 1-9
        case 0x30: return (SimulatorKeyUsage(0x27)!, false)  // 0
        case 0x0A, 0x0D: return (returnKey, false)
        case 0x09: return (tab, false)
        case 0x20: return (space, false)
        default: break
        }
        guard let entry = symbols[Character(scalar)] else { return nil }
        return (SimulatorKeyUsage(entry.usage)!, entry.shift)
    }

    private static let symbols: [Character: (usage: UInt32, shift: Bool)] = [
        "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
        "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
        "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
        "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
        "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
        ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
        "/": (0x38, false), "?": (0x38, true)
    ]
}
