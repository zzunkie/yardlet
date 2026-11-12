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

enum YardletPreferenceKeys {
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
