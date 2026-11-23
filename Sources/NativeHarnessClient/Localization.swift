import Foundation
#if os(Windows)
import WinSDK
#endif

enum L10n {
    /// Sentinel value passed to `Bundle.localizedString` so a missing key in a non-English
    /// `.lproj` catalog can be distinguished from a key whose translation matches the key itself.
    private static let missingSentinel = "\u{0000}__YARDLET_L10N_MISSING__"

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

    /// The English catalog (`en.lproj/Localizable.strings`), loaded once as the single source of
    /// truth and runtime fallback whenever another localization omits a key.
    private static let englishTable: [String: String] = stringsTable(for: "en", in: activeBundle)

    /// Reads `<languageCode>.lproj/Localizable.strings` from `bundle`, checking both standard
    /// bundle resource lookup and flat `.lproj` directories (as SwiftPM packages resources on
    /// Windows).
    static func stringsTable(for languageCode: String, in bundle: Bundle) -> [String: String] {
        var candidates: [URL] = []
        if let url = bundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: languageCode
        ) {
            candidates.append(url)
        }
        for folder in [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 }) {
            candidates.append(folder.appending(path: "\(languageCode).lproj/Localizable.strings"))
        }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                return table
            }
        }
        return [:]
    }

    /// The `.lproj` localization codes bundled in `bundle`, excluding `Base`.
    static func bundledLocalizations(in bundle: Bundle) -> [String] {
        let reported = bundle.localizations.filter { $0 != "Base" }
        if !reported.isEmpty { return reported }
        for folder in [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 }) {
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".lproj") }
                .map { String($0.dropLast(".lproj".count)) }
                .filter { $0 != "Base" }
            if !found.isEmpty { return found.sorted() }
        }
        return []
    }

    /// The `.lproj` localization codes bundled in the active app/module bundle.
    static var bundledLocalizations: [String] {
        bundledLocalizations(in: activeBundle)
    }

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

    /// Resolves `key` in `bundle`, falling back to `englishFallback[key]` when the bundle's active
    /// localization omits the key, and finally to `defaultValue`.
    static func resolve(
        _ key: String,
        in bundle: Bundle,
        englishFallback: [String: String],
        defaultValue: String
    ) -> String {
        let resolved = bundle.localizedString(forKey: key, value: missingSentinel, table: nil)
        if resolved != missingSentinel { return resolved }
        return englishFallback[key] ?? defaultValue
    }

    #if canImport(Darwin)
    static func string(_ key: String.LocalizationValue) -> String {
        let resolved = String(localized: key, bundle: activeBundle)
        if let englishFallback = englishTable[resolved], englishFallback != resolved,
           activeBundle.localizedString(forKey: resolved, value: missingSentinel, table: nil) == missingSentinel {
            return englishFallback
        }
        return resolved
    }
    #endif

    static func string(_ key: String) -> String {
        #if os(Windows)
        if let words = windowsLocalization.words[key] { return words }
        #endif
        return resolve(key, in: activeBundle, englishFallback: englishTable, defaultValue: key)
    }

    /// The key's words, falling back to English when the active localization omits the key,
    /// or `fallback` when no catalog has the key.
    static func string(_ key: String, fallback: String) -> String {
        #if os(Windows)
        if let words = windowsLocalization.words[key] { return words }
        #endif
        return resolve(key, in: activeBundle, englishFallback: englishTable, defaultValue: fallback)
    }

    /// The English keys of words the app shows in its language (more than one where keys share a translation), or the
    /// words themselves where they are English or not in the catalog, so Settings search finds a setting by its
    /// English name in any language.
    static func englishKeys(for words: String) -> [String] {
        keysByWords[words] ?? [words]
    }

    /// The key's words in each localization the app has, English first, without repeats: what Settings search finds
    /// a name or a synonym by, whatever language the app shows.
    static func translations(of key: String) -> [String] {
        var words = [englishTable[key] ?? key]
        if !words.contains(key) { words.append(key) }
        for language in bundledLocalizations where language != "en" {
            let translated = string(key, languageCode: language)
            if !words.contains(translated) { words.append(translated) }
        }
        let shown = string(key)
        if !words.contains(shown) { words.append(shown) }
        return words
    }

    private static let keysByWords: [String: [String]] = {
        #if os(Windows)
        let table = windowsLocalization.words
        #elseif canImport(Darwin)
        let table = activeBundle.url(forResource: "Localizable", withExtension: "strings")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        #else
        let table: [String: String] = [:]
        #endif
        var keys: [String: [String]] = [:]
        for (key, words) in englishTable.sorted(by: { $0.key < $1.key }) where words != key {
            keys[words, default: []].append(key)
        }
        for (key, words) in table.sorted(by: { $0.key < $1.key }) where words != key {
            if !(keys[words]?.contains(key) ?? false) {
                keys[words, default: []].append(key)
            }
        }
        return keys
    }()

    /// The localization the words come from. The bundle chose it as Yardlet opened and keeps it while
    /// Yardlet runs, whatever the language preference says since.
    static var shownLocalization: String? { activeBundle.preferredLocalizations.first }

    /// The localization the bundle would choose for a launch that prefers `languages`.
    static func localization(preferring languages: [String]) -> String? {
        Bundle.preferredLocalizations(from: activeBundle.localizations, forPreferences: languages).first
    }

    static func string(_ key: String, languageCode: String) -> String {
        string(key, languageCode: languageCode, in: activeBundle, englishFallback: englishTable)
    }

    /// Looks up `key` in `<languageCode>.lproj` inside `bundle`, falling back to `en.lproj`
    /// (not merely the raw key) when the target catalog omits the key or does not exist.
    static func string(
        _ key: String,
        languageCode: String,
        in bundle: Bundle,
        englishFallback: [String: String]? = nil
    ) -> String {
        let english = englishFallback ?? stringsTable(for: "en", in: bundle)
        if let path = bundle.path(forResource: languageCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return resolve(key, in: localizedBundle, englishFallback: english, defaultValue: key)
        }
        let table = stringsTable(for: languageCode, in: bundle)
        if let words = table[key] { return words }
        return english[key] ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }

    #if canImport(Darwin)
    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
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
/// it as Yardlet opens, so a choice applies from the next launch, which Settings › General offers as
/// Relaunch; switching while running would mix languages in menus, system strings and views already drawn.
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

    /// Languages whose `.lproj` catalog is bundled in this build, with System first.
    /// Adding a new shipped language only requires dropping its `.lproj` catalog and adding a case above.
    static var availableCases: [Self] {
        availableCases(bundledLocalizations: L10n.bundledLocalizations)
    }

    static func availableCases(bundledLocalizations: [String]) -> [Self] {
        let bundled = Set(bundledLocalizations.map { $0.lowercased() })
        return allCases.filter { $0 == .system || bundled.contains($0.rawValue.lowercased()) }
    }

    /// The language this app's own defaults ask for, or System when they ask for none. The list
    /// every app inherits from macOS is not a choice made for Yardlet.
    static func stored(in defaults: UserDefaults = .standard,
                       domain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) -> Self {
        guard let languages = defaults.persistentDomain(forName: domain)?[key] as? [String], !languages.isEmpty
        else { return .system }
        let codes = availableCases.filter { $0 != .system }.map(\.rawValue)
        return Bundle.preferredLocalizations(from: codes, forPreferences: languages).first
            .flatMap(Self.init(rawValue:)) ?? .system
    }

    /// Whether opening Yardlet with this choice would show it in another language than it shows now,
    /// so Settings offers to relaunch. System is the Mac's own languages, from the global domain: while
    /// Yardlet runs with a language of its own, the languages it inherits start with that one.
    func changesShownLanguage(in defaults: UserDefaults = .standard) -> Bool {
        let languages = self == .system
            ? defaults.persistentDomain(forName: UserDefaults.globalDomain)?[Self.key] as? [String] ?? Locale.preferredLanguages
            : [rawValue]
        return L10n.localization(preferring: languages) != L10n.shownLocalization
    }

    static func store(_ preference: Self, in defaults: UserDefaults = .standard) {
        if preference == .system {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([preference.rawValue], forKey: key)
        }
    }
}
