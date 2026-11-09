import Foundation
#if os(Windows)
import WinSDK
#endif

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

    #if os(Windows)
    /// Windows' display languages and the localization they prefer, with its words read from its strings file.
    /// Foundation outside Apple's platforms looks for the preferred languages only in `AppleLanguages`, which nothing
    /// writes on Windows, so the bundle answers in its development language whatever Windows shows, beside WinUI's
    /// own controls in Windows' language; a bundle made from a `.lproj` folder searches that same list. No words while
    /// Yardlet's own defaults name a language, or when Windows prefers the development language.
    private static let windowsLocalization: (languages: [String], chosen: String?, words: [String: String]) = {
        let languages = windowsDisplayLanguages()
        guard (UserDefaults.standard.array(forKey: AppLanguagePreference.key) ?? []).isEmpty else {
            return (languages, nil, [:])
        }
        // The resource bundle keeps its `.lproj` folders at its root on Windows; the resources folder, where a bundle
        // has one, is asked first.
        let lists = [activeBundle.resourceURL, activeBundle.bundleURL].compactMap { $0 }.map { folder in
            (folder, ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".lproj") }
                .map { String($0.dropLast(".lproj".count)) })
        }
        guard let found = lists.first(where: { !$0.1.isEmpty }) else { return (languages, nil, [:]) }
        let (folder, available) = found
        // A language as Windows names it ("ko-KR"), else its language alone ("ko").
        let chosen = languages.lazy.compactMap { tag in
            available.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
                ?? available.first { $0.caseInsensitiveCompare(String(tag.prefix { $0 != "-" })) == .orderedSame }
        }.first
        guard let chosen, chosen != activeBundle.developmentLocalization,
              let data = FileManager.default.contents(
                atPath: folder.appending(path: "\(chosen).lproj/Localizable.strings").path(percentEncoded: false)),
              let words = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return (languages, chosen, [:]) }
        return (languages, chosen, words)
    }()

    /// For the QA event log: the localization the words come from and the display languages it was chosen from.
    static var windowsLanguageNote: String {
        let localization = windowsLocalization
        return "\(localization.chosen ?? "none") (\(localization.words.count) words) from \(localization.languages.joined(separator: ", "))"
    }

    /// This user's Windows display languages, most preferred first, as BCP 47 names ("ko-KR", "en-US").
    private static func windowsDisplayLanguages() -> [String] {
        var count: ULONG = 0
        var length: ULONG = 0
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &length), length > 0 else { return [] }
        var buffer = [WCHAR](repeating: 0, count: Int(length))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &buffer, &length) else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
    }
    #endif

    #if canImport(Darwin)
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: activeBundle)
    }
    #endif

    static func string(_ key: String) -> String {
        #if os(Windows)
        if let words = windowsLocalization.words[key] { return words }
        #endif
        return activeBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The key's words, or `fallback` when the catalog does not have the key.
    static func string(_ key: String, fallback: String) -> String {
        #if os(Windows)
        if let words = windowsLocalization.words[key] { return words }
        #endif
        return activeBundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func string(_ key: String, languageCode: String) -> String {
        guard let path = activeBundle.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    // Foundation outside Apple's platforms has no `String.LocalizationValue`; there a key is the
    // English text itself, looked up in the same Localizable.strings.
    #if canImport(Darwin)
    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
    #else
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
    #endif
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
