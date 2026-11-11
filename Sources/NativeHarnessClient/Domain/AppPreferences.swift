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
