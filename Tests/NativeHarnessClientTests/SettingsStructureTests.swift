import XCTest
@testable import NativeHarnessClient

/// One Settings structure: each section is a sidebar entry with its own page, and the window's
/// account and harness entries open their sections.
final class SettingsStructureTests: XCTestCase {
    func testEverySectionIsOneSidebarEntryInOrder() {
        let all = SettingsSection.available(hasAccounts: true, hasConnectors: true, hasVault: true, hasRemote: true, hasCLIUpdates: true,
                                            hasInstructions: true, hasUsage: true)
        XCTAssertEqual(all, SettingsSection.allCases)
        XCTAssertEqual(SettingsSection.available(hasAccounts: true, hasConnectors: true),
            all.filter { $0 != .remote && $0 != .cliUpdates && $0 != .instructions && $0 != .vault && $0 != .usage })
        XCTAssertEqual(all[all.firstIndex(of: .accounts)! + 1], .usage, "Usage follows the accounts whose limits it shows")
        XCTAssertEqual(all.suffix(2), [.harnesses, .cliUpdates], "CLI Updates follows the harnesses it updates")
        XCTAssertEqual(Array(all.prefix(5)), [.general, .appearance, .notifications, .instructions, .accounts],
            "Yardlet Instructions is a personal setting, as the Codex app's custom instructions are, before the account")
        XCTAssertEqual(Set(all.map(\.title)).count, all.count, "No two entries share a name")
        XCTAssertEqual(SettingsSection.available(hasAccounts: false, hasConnectors: true, hasVault: true, hasRemote: true, hasCLIUpdates: true,
                                                 hasInstructions: true, hasUsage: true),
            all.filter { !$0.isConnectionSection })
        XCTAssertEqual(SettingsSection.available(hasAccounts: true, hasConnectors: false, hasVault: true, hasRemote: true, hasCLIUpdates: true,
                                                 hasInstructions: true, hasUsage: true),
            all.filter { $0 != .connectors })
        XCTAssertEqual(all.filter(\.isConnectionSection), [.accounts, .harnesses])
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
            "The sidebar's Connections entry opens Accounts")
        XCTAssertEqual(ConnectionEntryRoute.accounts(harness: .claudeCode), .settings(.accounts, harness: .claudeCode),
            "Manage accounts opens Accounts filtered to the task's harness")
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
}
