import Foundation

// Preferences whose screens or platform layers act on them, kept in the engine so the settings
// catalog (`YardletSettingCatalog`) can name them on any platform.

/// Settings › Appearance › Theme.
enum YardletAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }
}

/// One accent for controls, selections and links in the Mac app.
enum YardletAccentPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case system, ink, grove, iris

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .ink: L10n.string("Ink")
        case .grove: L10n.string("Grove")
        case .iris: L10n.string("Iris")
        }
    }

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        PlatformAppearanceSettings.accent(in: defaults)
    }
}

/// Opaque eight-bit sRGB, stored and exposed to agents as #RRGGBB.
struct ThemeRGB: Hashable, Codable {
    let value: Int

    init?(_ hex: String) {
        guard hex.utf8.count == 7, hex.first == "#",
              hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.value = value
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        value = Int(red) << 16 | Int(green) << 8 | Int(blue)
    }

    var hex: String { String(format: "#%06X", value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = Self(hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB")
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Settings › Appearance › Interface size.
enum YardletInterfaceSizePreference: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: L10n.string("Compact")
        case .standard: L10n.string("Default")
        case .large: L10n.string("Large")
        }
    }
}

/// View › Zoom In, Zoom Out and Actual Size (⌘+, ⌘− and ⌘0), as in the Claude and Codex apps: how much larger or
/// smaller than Settings' interface size the app draws its text, code and the controls sized from them. It is the
/// app's state, kept across launches, not a Settings row; Actual Size removes it.
enum InterfaceZoom {
    static let key = "YardletInterfaceZoom"
    /// A browser's steps around 100%, up to the size at which the sidebar and the panels, which keep their widths,
    /// still show a task's name.
    static let levels: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75]

    /// The level a stored value stands for: 1 for none, or for one not offered.
    static func level(_ stored: Double?) -> Double {
        stored.flatMap { levels.contains($0) ? $0 : nil } ?? 1
    }

    static func current(in defaults: UserDefaults = .yardlet) -> Double {
        level(defaults.object(forKey: key) as? Double)
    }

    static func zoomIn(in defaults: UserDefaults = .yardlet) {
        levels.first { $0 > current(in: defaults) }.map { set($0, in: defaults) }
    }

    static func zoomOut(in defaults: UserDefaults = .yardlet) {
        levels.last { $0 < current(in: defaults) }.map { set($0, in: defaults) }
    }

    static func actualSize(in defaults: UserDefaults = .yardlet) {
        set(1, in: defaults)
    }

    private static func set(_ level: Double, in defaults: UserDefaults) {
        if level == 1 { defaults.removeObject(forKey: key) } else { defaults.set(level, forKey: key) }
    }
}

enum YardletPreferenceKeys {
    static let accent = "YardletAccent"
    static let appearance = "YardletAppearance"
    static let interfaceSize = "YardletInterfaceSize"
}

/// Settings › Appearance › Code font and Code font size: one font for code blocks, diffs, command output, open files
/// and the terminal, as the Claude app's code font applies to all of them. The default is what they drew before, the
/// system's monospaced face at 12 points, so it changes nothing. The interface size multiplies on top.
enum CodeFontPreference {
    /// A font family's name; missing or empty for the system's monospaced face.
    static let nameKey = "YardletCodeFont"
    /// Points, as a string (`sizes`).
    static let sizeKey = "YardletCodeFontSize"
    /// The size code's sizes were set for: what a view drew at `n` points it draws at `n × size / standardSize`.
    static let standardSize = 12
    static let sizes = [10, 11, 12, 13, 14, 15, 16, 18, 20]

    static func name(in defaults: UserDefaults = .yardlet) -> String {
        defaults.string(forKey: nameKey) ?? ""
    }

    static func size(in defaults: UserDefaults = .yardlet) -> Int {
        size(defaults.string(forKey: sizeKey))
    }

    /// A stored size, the standard one for anything not offered.
    static func size(_ stored: String?) -> Int {
        stored.flatMap(Int.init).flatMap { sizes.contains($0) ? $0 : nil } ?? standardSize
    }
}

/// Settings › General › Send shortcut, as the Codex app's: which Return sends from a composer. Return sends by
/// default, as before. The other two keep Return for a new line, when the draft already has more than one line or
/// always, and send with ⌘Return, which sends in every mode. While a turn runs the key that sends the other way
/// (the follow-up setting's other) is ⌘Return where Return sends and ⇧⌘Return where ⌘Return does, as the Codex
/// app moves it.
enum SendShortcut: String, CaseIterable, Identifiable, Sendable {
    case `return`
    case commandReturnForMultiline
    case commandReturn

    static let preferenceKey = "YardletSendShortcut"

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .return
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .return: L10n.string("Return")
        case .commandReturnForMultiline: L10n.string("⌘Return for multiline")
        case .commandReturn: L10n.string("Always ⌘Return")
        }
    }

    /// Whether a plain Return sends this draft; otherwise it adds a line.
    func returnSends(_ draft: String) -> Bool {
        switch self {
        case .return: true
        case .commandReturnForMultiline: !draft.contains(where: \.isNewline)
        case .commandReturn: false
        }
    }

#if os(Windows)
    // Windows names its keys as its own apps write them: Enter, with Ctrl where the Mac has Command.
    var sendSymbol: String { self == .return ? "Enter" : "Ctrl+Enter" }
    var alternateSymbol: String { self == .return ? "Ctrl+Enter" : "Ctrl+Shift+Enter" }
    var sendKeyName: String { sendSymbol }
    var alternateKeyName: String { alternateSymbol }
#elseif os(macOS)
    var sendSymbol: String { MacShortcutPreferences.shared.binding(for: .composerSend, send: self)?.displayText ?? "" }
    var alternateSymbol: String { MacShortcutPreferences.shared.binding(for: .composerAlternate, send: self)?.displayText ?? "" }
    var sendKeyName: String {
        MacShortcut.composerSend.isCustomized || sendSymbol.isEmpty ? sendSymbol : (self == .return ? "Return" : "Command-Return")
    }
    var alternateKeyName: String {
        MacShortcut.composerAlternate.isCustomized || alternateSymbol.isEmpty ? alternateSymbol :
            (self == .return ? "Command-Return" : "Shift-Command-Return")
    }
#else
    /// The key that sends in this mode whatever the draft, as a menu writes it.
    var sendSymbol: String { self == .return ? "↩" : "⌘↩" }
    /// The key that sends the other way while a turn runs, as a menu writes it.
    var alternateSymbol: String { self == .return ? "⌘↩" : "⇧⌘↩" }
    /// `sendSymbol` in words, for sentences and VoiceOver.
    var sendKeyName: String { self == .return ? "Return" : "Command-Return" }
    /// `alternateSymbol` in words.
    var alternateKeyName: String { self == .return ? "Command-Return" : "Shift-Command-Return" }
#endif
}

/// Settings › General › "Keep the screen unlocked while tasks work". Off by default: a Mac left alone
/// stays unlocked while it is on (docs/SLEEP_PREVENTION.md).
enum KeepScreenAwakePreference {
    static let key = "YardletKeepScreenAwakeWhileWorking"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Settings › General › "Keep tasks working with the lid closed". Off by default. Turning it on asks
/// macOS to allow Yardlet's lid helper, a launch daemon in the bundle; turning it off removes the
/// helper (docs/SLEEP_PREVENTION.md).
enum LidClosedWorkPreference {
    static let key = "YardletKeepWorkingWithLidClosed"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.bool(forKey: key)
    }
}
