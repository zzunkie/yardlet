import Foundation

/// Where a link into Settings lands: a section, and in it the row to scroll to and highlight (`anchor`), or the
/// Keyboard shortcuts page searched for a command (`shortcutQuery`).
struct SettingsDestination: Equatable, Sendable {
    var section: SettingsSection
    var anchor: String?
    var shortcutQuery: String?

    init(_ section: SettingsSection, anchor: String? = nil, shortcutQuery: String? = nil) {
        self.section = section
        self.anchor = anchor
        self.shortcutQuery = shortcutQuery
    }
}

/// One thing Settings search finds: a section, a setting from the catalog, or a part of a page the catalog does
/// not list (an action, a list or a service to connect), with the words it is found by.
struct SettingsSearchItem: Identifiable, Equatable, Sendable {
    enum Kind: Int, Sendable {
        case section
        case setting
        case pageItem
        /// A command whose key Keyboard shortcuts changes; listed after everything else.
        case command
    }

    let id: String
    let kind: Kind
    let destination: SettingsDestination
    /// The name a result shows, in the person's language.
    let title: String
    /// The name in the app's other languages, ranked as the name is.
    let titleWords: [String]
    /// What else it is found by: the lines under it and its synonyms, in each language.
    let words: [String]

    @MainActor
    init(id: String, kind: Kind, destination: SettingsDestination, title: String, words: [String] = []) {
        self.id = id
        self.kind = kind
        self.destination = destination
        self.title = title
        let titleWords = SettingsSearch.titleWords(title)
        self.titleWords = titleWords
        self.words = words.filter { !titleWords.contains($0) }
    }

    var section: SettingsSection { destination.section }

    /// A page item: `title` and `keywords` are English keys, so the item is found by its English words and by
    /// their translation.
    @MainActor
    static func pageItem(_ anchor: String, in section: SettingsSection, title: String, keywords: String? = nil)
        -> SettingsSearchItem {
        SettingsSearchItem(id: "item:\(anchor):\(title)", kind: .pageItem,
                           destination: SettingsDestination(section, anchor: anchor),
                           title: L10n.string(title), words: SettingsSearch.words(keywords))
    }
}

/// Settings search, as macOS System Settings searches from the top of its sidebar: what a window offers
/// (`items`), and what matches a query, best first (`results`). The command palette lists the same results.
@MainActor
enum SettingsSearch {
    /// Everything a window offers, in sidebar order: each section, then its settings and page items. `settings`
    /// are the catalog's settings shown in this window, each with the row it lands on (`target(in:)`); a section
    /// the window does not offer leaves its items out.
    static func items(sections: [SettingsSection], settings: [(setting: YardletSetting, target: YardletSetting)],
                      pageItems: [SettingsSearchItem] = [], commands: [SettingsSearchItem] = []) -> [SettingsSearchItem] {
        let offered = Set(sections)
        var items: [SettingsSearchItem] = []
        for section in sections {
            items.append(SettingsSearchItem(id: "section:\(section.rawValue)", kind: .section,
                destination: SettingsDestination(section), title: section.title,
                words: words(section.keywords)))
            // Each of the theme's colors is a setting for the agent's tools; search finds their rows by name instead.
            for (setting, target) in settings where setting.section == section && offered.contains(target.section)
                && !setting.isColor {
                items.append(SettingsSearchItem(id: "setting:\(setting.id)", kind: .setting,
                    destination: SettingsDestination(target.section, anchor: target.id), title: setting.title,
                    words: [setting.detail, setting.note, setting.hint].compactMap(\.self) + words(setting.keywords)))
            }
            items += pageItems.filter { $0.section == section }
        }
        return items + commands.filter { offered.contains($0.section) }
    }

    /// The items whose words have every word of `query`, best first: a name that starts with the query, then one
    /// with a word that starts with it, then one that has it anywhere, then one that has each word, then one whose
    /// name has some of the words and its other words the rest, then one found by its other words alone. A section
    /// whose name matches comes before its settings, as System Settings lists panes first; found by other words, a
    /// setting comes before its section, being the more exact answer. Ties keep sidebar order, and commands come
    /// last. An empty query finds nothing.
    static func results(_ query: String, in items: [SettingsSearchItem], limit: Int = 40) -> [SettingsSearchItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let phrase = terms.joined(separator: " ")
        let scored = items.enumerated().compactMap { index, item -> (score: Int, index: Int, item: SettingsSearchItem)? in
            let titles = [item.title] + item.titleWords
            let own = titles + item.words
            // The section's name narrows ("browser cookies") but finds nothing alone: otherwise every command would
            // be found by "shortcut".
            let section = item.kind == .section ? [] : [item.section.title] + SettingsSearch.titleWords(item.section.title)
            guard terms.contains(where: { term in own.contains { matches($0, term) } }),
                  terms.allSatisfy({ term in (own + section).contains { matches($0, term) } }) else { return nil }
            let score: Int
            if titles.contains(where: { matches($0, phrase, anchored: true) }) {
                score = 0
            } else if titles.contains(where: { title in wordStarts(title, phrase) }) {
                score = 1
            } else if titles.contains(where: { matches($0, phrase) }) {
                score = 2
            } else if terms.allSatisfy({ term in titles.contains { matches($0, term) } }) {
                score = 3
            } else if terms.contains(where: { term in titles.contains { matches($0, term) } }) {
                score = 4
            } else {
                score = 5
            }
            let kind = item.kind == .section ? (score <= 2 ? 0 : 1) : (score <= 2 ? 1 : 0)
            return (score + (item.kind == .command ? 10 : 0), kind * 100_000 + index, item)
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.prefix(limit).map(\.item)
    }

    /// Where links land on the parts of pages the catalog does not list.
    enum Anchor {
        static let macOSNotifications = "macos_notifications"
        static let addConnector = "add_connector"
        static let importLogins = "import_logins"
        static let twoFactorCodes = "two_factor_codes"
        static let pairDevice = "pair_device"
        static let pairedDevices = "paired_devices"
        static let addAccount = "add_account"
        static let cliVersions = "cli_versions"

        /// A row of the theme's colors in Appearance (`ThemeField`), light and dark side by side.
        nonisolated static func themeColor(_ field: String) -> String { "theme_\(field)" }

        /// A service Connectors sets up in one go, by its preset.
        nonisolated static func setUp(_ preset: String) -> String { "set_up_\(preset)" }
    }

    /// The parts of pages the catalog does not list (actions, lists, services to connect), where search and links
    /// land. A window that does not offer a part's section leaves it out (`items`).
    static let pageItems: [SettingsSearchItem] = [
        .pageItem(Anchor.macOSNotifications, in: .notifications, title: "macOS notifications",
                  keywords: "allow notifications, notification permission, System Settings"),
        .pageItem(YardletSetting.codeFontSize.id, in: .appearance, title: "Code font",
                  keywords: "monospace, programming font, terminal font"),
        .pageItem(Anchor.themeColor("background"), in: .appearance, title: "Background",
                  keywords: "theme color, custom color, background color"),
        .pageItem(Anchor.themeColor("text"), in: .appearance, title: "Text color", keywords: "theme color, custom color"),
        .pageItem(Anchor.addConnector, in: .connectors, title: "Add connector",
                  keywords: "MCP server, custom connector, new connector"),
        .pageItem(Anchor.setUp("gmail"), in: .connectors, title: "Google",
                  keywords: "Gmail, Google Calendar, Google Drive, Google Docs"),
        .pageItem(Anchor.setUp("outlook-mail"), in: .connectors, title: "Microsoft 365",
                  keywords: "Outlook, OneDrive, Teams, Office"),
        .pageItem(Anchor.setUp("slack"), in: .connectors, title: "Slack", keywords: "Slack workspace"),
        .pageItem(Anchor.setUp("zoom-meetings"), in: .connectors, title: "Zoom", keywords: "Zoom meetings"),
        .pageItem(Anchor.importLogins, in: .vault, title: "Import from Another Browser…",
                  keywords: "Chrome, Safari, Firefox, Whale, Edge, Arc, import passwords, browser sign-ins"),
        .pageItem(Anchor.importLogins, in: .vault, title: "Import CSV…", keywords: "CSV, 1Password, Bitwarden, export file"),
        .pageItem(Anchor.importLogins, in: .vault, title: "Import QR Code…", keywords: "QR code, authenticator app"),
        .pageItem(Anchor.importLogins, in: .vault, title: "Add sign-in", keywords: "new password, save password"),
        .pageItem(Anchor.twoFactorCodes, in: .vault, title: "Two-factor codes",
                  keywords: "2FA, OTP, verification code, authenticator"),
        .pageItem(Anchor.pairDevice, in: .remote, title: "Pair a device", keywords: "QR code, phone, pairing link"),
        .pageItem(Anchor.pairedDevices, in: .remote, title: "Paired devices", keywords: "remove device, device permissions"),
        .pageItem(Anchor.addAccount, in: .accounts, title: "Add account", keywords: "sign in, log in, another account"),
        .pageItem(Anchor.cliVersions, in: .cliUpdates, title: "Check for Updates",
                  keywords: "CLI version, update now, use newest version"),
    ]

    /// A comma-separated list of synonyms, an English key in `Localizable.strings`, as its words in English and in
    /// each translation, so a word in either language finds it whatever language the app shows.
    static func words(_ keywords: String?) -> [String] {
        guard let keywords else { return [] }
        return translations(of: keywords)
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A name as the app shows it, in English and in each translation, the shown one left out.
    static func titleWords(_ title: String) -> [String] {
        var words: [String] = []
        for key in L10n.englishKeys(for: title) {
            for word in translations(of: key) where word != title && !words.contains(word) { words.append(word) }
        }
        return words
    }

    /// `L10n.translations(of:)`, kept once read: search reads every name and synonym at each change of the words.
    private static func translations(of key: String) -> [String] {
        if let known = translationCache[key] { return known }
        let words = L10n.translations(of: key)
        translationCache[key] = words
        return words
    }

    private static var translationCache: [String: [String]] = [:]

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    private static func matches(_ text: String, _ term: String, anchored: Bool = false) -> Bool {
        text.range(of: term, options: anchored ? options.union(.anchored) : options) != nil
    }

    private static func wordStarts(_ text: String, _ term: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" || $0 == "(" || $0 == "·" })
            .contains { matches(String($0), term, anchored: true) }
            || matches(text, term, anchored: true)
    }
}

extension YardletSetting {
    var isColor: Bool {
        if case .color = values { true } else { false }
    }

    /// Where a link to this setting lands: its section, and its row, or the row it shows under on the same page.
    var destination: SettingsDestination {
        let parent = shownWhileOn.flatMap(YardletSettingCatalog.setting)
        return SettingsDestination(section, anchor: parent?.section == section ? parent?.id : id)
    }

    /// The row a link to this setting lands on in this window, or nil where Settings does not offer it: the
    /// setting's own row, or the switch it shows under when that switch is off or draws it in its own row.
    func target(in context: YardletSettingsContext) -> YardletSetting? {
        guard offered?(context) ?? true else { return nil }
        if case let .app(read, _) = storage, read(context) == nil { return nil }
        guard let parent = shownWhileOn.flatMap(YardletSettingCatalog.setting) else { return self }
        guard let parentTarget = parent.target(in: context) else { return nil }
        if parent.section == section { return parentTarget }
        return parent.value(in: context) == Self.on ? self : parentTarget
    }
}
