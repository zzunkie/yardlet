import Foundation

enum L10n {
    /// Any packaged app owns these resources, including separately identified QA builds.
    /// SwiftPM tests and previews keep using Bundle.module when they have no app resources.
    /// Decided once: every string a view shows asks for it, and looking the resource up searched
    /// the bundle each time (measured in scroll hitches while new rows came into view).
    private static let activeBundle: Bundle = {
        if Bundle.main.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"
        ) != nil {
            return .main
        }
        return .module
    }()

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: activeBundle)
    }

    static func string(_ key: String) -> String {
        activeBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, languageCode: String) -> String {
        guard let path = activeBundle.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
}

/// Yardlet's language, kept where macOS keeps each app's own: `AppleLanguages` in the app's
/// defaults, the value System Settings › General › Language & Region › Applications writes, so the
/// two never disagree. System removes the key and leaves nothing behind. AppKit and the bundle read
/// it as Yardlet opens, so a choice applies from the next launch; switching while running would mix
/// languages in menus, system strings and views already drawn.
enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"

    static let key = "AppleLanguages"

    var id: Self { self }

    /// Each language in its own words; only System follows the language Yardlet shows.
    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .english: "English"
        case .korean: "한국어"
        }
    }

    /// The language this app's own defaults ask for, or System when they ask for none. The list
    /// every app inherits from macOS is not a choice made for Yardlet.
    static func stored(in defaults: UserDefaults = .standard,
                       domain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) -> Self {
        guard let languages = defaults.persistentDomain(forName: domain)?[key] as? [String], !languages.isEmpty
        else { return .system }
        let codes = allCases.filter { $0 != .system }.map(\.rawValue)
        return Bundle.preferredLocalizations(from: codes, forPreferences: languages).first
            .flatMap(Self.init(rawValue:)) ?? .system
    }

    static func store(_ preference: Self, in defaults: UserDefaults = .standard) {
        if preference == .system {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([preference.rawValue], forKey: key)
        }
    }
}
