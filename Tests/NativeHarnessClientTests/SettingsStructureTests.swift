import XCTest
@testable import NativeHarnessClient

/// One Settings structure: each section is a sidebar entry with its own page, and the window's
/// account and harness entries open their sections.
final class SettingsStructureTests: XCTestCase {
    @MainActor
    func testEverySectionIsOneSidebarEntryInOrder() {
        let all = SettingsSection.available(hasAccounts: true, hasConnectors: true, hasVault: true, hasRemote: true,
                                            hasYardletAccount: true, hasCLIUpdates: true, hasInstructions: true, hasUsage: true)
        XCTAssertEqual(all, SettingsSection.allCases)
        XCTAssertEqual(all.first, .yardletAccount, "The Yardlet account comes first, as both apps put the account first")
        XCTAssertNil(SettingsSection.yardletAccount.group)
        XCTAssertEqual(SettingsSection.Group.allCases.map { group in all.filter { $0.group == group } }, [
            [.general, .appearance, .keyboardShortcuts, .notifications, .instructions],
            [.connectors, .browser, .vault, .remote],
            [.accounts, .usage, .harnesses, .cliUpdates],
        ])
        XCTAssertEqual(all.dropFirst().compactMap(\.group), SettingsSection.Group.allCases.flatMap { group in
            all.filter { $0.group == group }.map { _ in group } }, "Each heading's sections follow one another")
        XCTAssertEqual(SettingsSection.available(hasAccounts: true, hasConnectors: true),
            all.filter { ![.yardletAccount, .remote, .cliUpdates, .instructions, .vault, .usage].contains($0) })
        XCTAssertEqual(all[all.firstIndex(of: .accounts)! + 1], .usage, "Usage follows the accounts whose limits it shows")
        XCTAssertEqual(all.last, .cliUpdates, "CLI Updates follows the harnesses it updates")
        XCTAssertEqual(Set(all.map(\.title)).count, all.count, "No two entries share a name")
        XCTAssertEqual(SettingsSection.available(hasAccounts: false, hasConnectors: true, hasVault: true, hasRemote: true,
                                                 hasYardletAccount: true, hasCLIUpdates: true, hasInstructions: true, hasUsage: true),
            all.filter { !$0.isConnectionSection })
        XCTAssertEqual(SettingsSection.available(hasAccounts: true, hasConnectors: false, hasVault: true, hasRemote: true,
                                                 hasYardletAccount: true, hasCLIUpdates: true, hasInstructions: true, hasUsage: true),
            all.filter { $0 != .connectors })
        XCTAssertEqual(all.filter(\.isConnectionSection), [.accounts, .harnesses])

        // Every General row sits under one of its headings, and the catalog lists them heading by heading,
        // so a row without one is never left out of the page.
        let general = YardletSettingCatalog.all.filter { $0.section == .general }
        XCTAssertEqual(general.compactMap(\.generalGroup).count, general.count)
        XCTAssertEqual(general.compactMap(\.generalGroup), GeneralSettingsGroup.allCases.flatMap { group in
            general.filter { $0.generalGroup == group }.map { _ in group } })
        XCTAssertTrue(YardletSettingCatalog.all.filter { $0.section != .general }.allSatisfy { $0.generalGroup == nil })
    }

    /// Settings search finds every section and every setting the window shows by its name in English and in
    /// Korean, whatever language the run shows, lands each on its row, and puts what a person types for a common
    /// wish first.
    @MainActor
    func testSettingsSearchFindsEverySettingByNameAndCommonWishesFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("SettingsSearch")))
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([:]), repository: InMemoryVaultRepository(items: []), hmac: MacVault.hmac,
            isAllowedBuild: true, confirm: { _ in true }, defaults: .vaultTests()))
        let context = YardletSettingsContext(defaults: defaults, vault: vault)
        let sections = SettingsSection.available(hasAccounts: true, hasConnectors: true, hasVault: true, hasRemote: true,
                                                 hasYardletAccount: true, hasCLIUpdates: true, hasInstructions: true,
                                                 hasUsage: true)
        let settings = YardletSettingCatalog.all.compactMap { setting in setting.target(in: context).map { (setting, $0) } }
        let items = SettingsSearch.items(sections: sections, settings: settings, pageItems: SettingsSearch.pageItems,
                                         commands: KeyboardShortcutsSettings.searchItems)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "Every item has its own id")

        func first(_ query: String) -> SettingsSearchItem? { SettingsSearch.results(query, in: items).first }
        for item in items where item.kind != .command {
            let key = L10n.englishKeys(for: item.title)[0]
            for name in [item.title, key, L10n.string(key, languageCode: "ko")] {
                XCTAssertTrue(SettingsSearch.results(name, in: items).contains { $0.id == item.id },
                              "\(item.id) is found by “\(name)”")
            }
        }
        for (setting, target) in settings where !setting.isColor {
            let found = items.first { $0.id == "setting:\(setting.id)" }
            XCTAssertEqual(found?.destination, SettingsDestination(target.section, anchor: target.id), setting.id)
        }

        for (query, expected) in [
            ("sound", "setting:notification_sound"), ("알림 소리", "setting:notification_sound"),
            ("Catppuccin", "setting:accent"), ("조수 웅덩이", "setting:accent"), ("dark", "setting:theme"), ("다크 모드", "setting:theme"), ("language", "setting:language"),
            ("언어", "setting:language"), ("cookies", "setting:keep_cookies"), ("API 키", "setting:hide_keys_and_tokens"),
            ("pair phone", "item:pair_device:Pair a device"), ("휴대폰", "item:pair_device:Pair a device"), ("add account", "item:add_account:Add account"),
            ("slack", "item:set_up_slack:Slack"), ("import chrome", "item:import_logins:Import from Another Browser…"),
            ("context limit", "setting:claude_code_context_limit"), ("shortcut", "section:keyboardShortcuts"),
            ("terminal location", "setting:terminal_location"), ("usage", "section:usage"),
            ("browser cookies", "setting:keep_cookies"), ("브라우저 쿠키", "setting:keep_cookies"),
        ] {
            XCTAssertEqual(first(query)?.id, expected, "“\(query)” finds \(expected) first")
        }

        // A row drawn under another lands on that one; one shown only while another is on lands on that switch while
        // it is off.
        XCTAssertEqual(items.first { $0.id == "setting:memory_saver_level" }?.destination,
                       SettingsDestination(.browser, anchor: YardletSetting.memorySaver.id))
        XCTAssertEqual(items.first { $0.id == "setting:new_mail" }?.destination,
                       SettingsDestination(.general, anchor: YardletSetting.mailbox.id))
        // A command lands on Keyboard shortcuts searched for it, after the settings the words find.
        let zoom = SettingsSearch.results("zoom", in: items)
        XCTAssertEqual(zoom.first?.id, "item:set_up_zoom-meetings:Zoom")
        let command = try XCTUnwrap(zoom.first { $0.kind == .command })
        XCTAssertEqual(command.destination.section, .keyboardShortcuts)
        XCTAssertEqual(command.destination.shortcutQuery, command.title)
        XCTAssertTrue(zoom.drop { $0.kind != .command }.allSatisfy { $0.kind == .command })
        XCTAssertFalse(SettingsSearch.results("shortcut", in: items).contains { $0.kind == .command },
                       "A section's name alone finds its section and settings, not every command on its page")
        // A window without a section finds nothing of it, and no words find nothing.
        let withoutVault = SettingsSearch.items(sections: sections.filter { $0 != .vault }, settings: settings,
                                                pageItems: SettingsSearch.pageItems)
        XCTAssertFalse(SettingsSearch.results("import chrome", in: withoutVault).contains { $0.section == .vault })
        XCTAssertTrue(SettingsSearch.results("   ", in: items).isEmpty)
    }

    func testEachSectionIsReachableFromTheKeyboardAndByName() {
        let ids = SettingsSection.available(hasAccounts: true, hasConnectors: true).map(\.rawValue)
        var visited = [ids[0]]
        while let next = SettingsSectionNavigationProjection.targetSectionID(in: ids, focusedID: visited.last, offset: 1) {
            visited.append(next)
        }
        XCTAssertEqual(visited, ids)
        let available = SettingsSection.available(hasAccounts: true, hasConnectors: true)
        for section in available {
            XCTAssertEqual(SettingsSection.initial(section.rawValue, available: available), section)
        }
        XCTAssertEqual(SettingsSection.initial(nil, available: available), .general)
        XCTAssertEqual(SettingsSection.initial("git", available: available), .general)
        XCTAssertEqual(SettingsSection.initial("accounts", available: available.filter { !$0.isConnectionSection }),
            .general, "A section the window does not offer opens General")
    }

    func testTheWindowsAccountEntriesOpenTheirSettingsSections() {
        XCTAssertEqual(ConnectionEntryRoute.accounts(), .settings(.accounts, harness: nil),
            "The sidebar's Connections entry opens Harness Accounts")
        XCTAssertEqual(ConnectionEntryRoute.accounts(harness: .claudeCode), .settings(.accounts, harness: .claudeCode),
            "Manage accounts opens Harness Accounts filtered to the task's harness")
        XCTAssertEqual(ConnectionEntryRoute.harnesses, .settings(.harnesses, harness: nil))
        XCTAssertEqual(ConnectionEntryRoute.accounts(harness: .claudeCode, adds: true), .accountSheet,
            "Adding an account from a new task keeps its sheet, which returns to the draft")
        XCTAssertEqual(ConnectionEntryRoute.accounts(harness: .codex, connects: true), .accountSheet)
    }

    func testTheAccountsListStartsWithTheHarnessesInUse() throws {
        let catalog = HarnessCatalog.builtIns.map(\.id)
        let available = AccountHarnessScope.available(catalog: catalog,
            installed: [.codex, .claudeCode, .museCode, .grokBuild], savedAccounts: [.claudeCode],
            signedInDefaults: [.openCode])
        XCTAssertEqual(available, catalog.filter { [.codex, .claudeCode, .museCode, .grokBuild, .openCode].contains($0) })

        let inUse = AccountHarnessScope.inUse(available: available, withTasks: [.codex, .claudeCode],
            savedAccounts: [.claudeCode], chosenForNewTask: .codex)
        XCTAssertEqual(inUse, catalog.filter { [.codex, .claudeCode].contains($0) },
            "Installed harnesses without tasks or accounts stay out of the default list")
        XCTAssertEqual(AccountHarnessScope.inUse(available: available, withTasks: [], savedAccounts: [],
            chosenForNewTask: .grokBuild), [.grokBuild], "The harness chosen for the next task is in use")
        XCTAssertEqual(AccountHarnessScope.inUse(available: available, withTasks: [], savedAccounts: [],
            chosenForNewTask: nil), available, "Before anything is in use the list shows every harness")

        // A harness an agent ran a subagent on in the last 30 days is in use. The record keeps the
        // harness and the time only, drops older entries and goes once none is left.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("SettingsStructureTests")))
        let now = Date(), day: TimeInterval = 24 * 60 * 60
        AccountHarnessScope.SubagentUse.note(.museCode, at: now.addingTimeInterval(-31 * day), in: defaults)
        AccountHarnessScope.SubagentUse.note(.grokBuild, at: now.addingTimeInterval(-29 * day), in: defaults)
        let withSubagents = AccountHarnessScope.SubagentUse.harnesses(in: defaults, now: now)
        XCTAssertEqual(withSubagents, [.grokBuild], "A subagent run more than 30 days ago no longer counts")
        XCTAssertEqual(AccountHarnessScope.inUse(available: available, withTasks: [.codex, .claudeCode],
            withSubagents: withSubagents, savedAccounts: [.claudeCode], chosenForNewTask: .codex),
            catalog.filter { [.codex, .claudeCode, .grokBuild].contains($0) })
        let key = AccountHarnessScope.SubagentUse.key
        let saved = defaults.dictionary(forKey: key) ?? [:]
        XCTAssertEqual(saved.keys.sorted(), [HarnessKind.grokBuild.rawValue, HarnessKind.museCode.rawValue].sorted())
        XCTAssertTrue(saved.values.allSatisfy { $0 is Date })
        AccountHarnessScope.SubagentUse.prune(in: defaults, now: now)
        XCTAssertEqual(defaults.dictionary(forKey: key)?.keys.sorted(), [HarnessKind.grokBuild.rawValue])
        AccountHarnessScope.SubagentUse.prune(in: defaults, now: now.addingTimeInterval(2 * day))
        XCTAssertNil(defaults.object(forKey: key))

        XCTAssertEqual(AccountHarnessScope.harnesses(for: .inUse, available: available, inUse: inUse), inUse)
        XCTAssertEqual(AccountHarnessScope.harnesses(for: .all, available: available, inUse: inUse), available,
            "The filter still reaches every harness")
        XCTAssertEqual(AccountHarnessScope.harnesses(for: .harness(.museCode), available: available, inUse: inUse),
            [.museCode])
        XCTAssertEqual(AccountHarnessScope.Filter.harness(.museCode).harness, .museCode)
        XCTAssertNil(AccountHarnessScope.Filter.all.harness)
    }

    /// The Settings sheet fits inside the window it opens on, down to the window's minimum size.
    func testTheSettingsSheetFitsInsideItsWindow() {
        XCTAssertEqual(SettingsCenterView.fittingSize(in: CGSize(width: 1512, height: 949)), SettingsCenterView.preferredSize)
        let smallest = SettingsCenterView.fittingSize(in: CGSize(width: 760, height: 560))
        XCTAssertLessThanOrEqual(smallest.width, 760 - 48)
        XCTAssertLessThanOrEqual(smallest.height, 560 - 48)
        XCTAssertEqual(SettingsCenterView.fittingSize(in: .zero), SettingsCenterView.preferredSize, "Before the window is measured")
    }

    /// Settings' rows read the settings kept in Yardlet's defaults with `@AppStorage`, which follows every
    /// write to the store for a key with a dot in it (`PreferenceKeyCarryOver`). A value saved under a key's
    /// earlier name is copied to its name now once, one saved there already stays, and the earlier name keeps
    /// its value for a build from before the change.
    @MainActor
    func testSettingsKeptInDefaultsHaveKeysWithoutDotsAndKeepTheirSavedValues() throws {
        let keys = YardletSettingCatalog.all.compactMap { setting -> String? in
            switch setting.storage {
            case let .flag(key, _), let .choice(key, _): key
            case .app: nil
            }
        }
        XCTAssertFalse(keys.isEmpty)
        for key in keys { XCTAssertFalse(key.contains("."), key) }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("PreferenceKeyCarryOver")))
        defaults.set(false, forKey: "Yardlet.nextMessageSuggestions")
        defaults.set("right", forKey: "Yardlet.terminalLocation")
        defaults.set("compact", forKey: "Yardlet.interfaceSize")
        defaults.set("large", forKey: YardletPreferenceKeys.interfaceSize)
        PreferenceKeyCarryOver.run(in: defaults)
        XCTAssertFalse(NextMessageSuggestionPreference.isOn(in: defaults))
        XCTAssertEqual(defaults.string(forKey: TerminalLocation.key), "right")
        XCTAssertEqual(defaults.string(forKey: YardletPreferenceKeys.interfaceSize), "large", "Saved under its name now")
        XCTAssertEqual(defaults.object(forKey: "Yardlet.nextMessageSuggestions") as? Bool, false)

        defaults.set(true, forKey: NextMessageSuggestionPreference.key)
        PreferenceKeyCarryOver.run(in: defaults)
        XCTAssertTrue(NextMessageSuggestionPreference.isOn(in: defaults), "Copied once")
    }
}
