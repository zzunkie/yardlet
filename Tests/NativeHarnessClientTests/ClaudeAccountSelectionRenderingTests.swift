import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ClaudeAccountSelectionRenderingTests: XCTestCase {
    /// The task account sheet's rows for a Claude task: the accounts that share its history, each
    /// with its plan limits, in both appearances. Rendered without a window.
    func testClaudeTaskAccountSheetShowsSharedAccountsAndTheirLimits() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-account-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let store = ProviderConnectionStore()
        var accounts: [ProviderConnection] = []
        for (name, short, weekly) in [("personal@example.test", 2.0, 95.0), ("work@example.test", 0.0, 100.0)] {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"), withDestinationURL: projects)
            let connection = ProviderConnection(id: name, name: name, harness: .claudeCode, providerID: nil,
                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            accounts.append(connection)
            let usage = try XCTUnwrap(ClaudeUsageProbe.usage(from: try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":\#(short)},
              {"kind":"weekly_all","group":"weekly","percent":\#(weekly),"resets_at":"2030-01-02T00:00:00+00:00"},
              {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Fable"}}}]}}
            """#.utf8))))
            store.publish(HarnessAccountSnapshot(id: name, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: name, accountPlan: "Max", detail: "", credentialOwner: "Claude Code", checkedAt: Date(),
                usage: usage, canLogin: false, canLogout: true), for: connection)
        }
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Switch Yardlet account", connection: accounts[0])
        let directory = try WindowlessRender.directory("claude-account-qa")
        for appearance in [ColorScheme.light, .dark] {
            // The sheet lists these rows inside a ScrollView, which ImageRenderer does not draw.
            let rows = AccountListProjection.choices(.switchTask(session), store: store)
            XCTAssertEqual(rows.compactMap(\.connection), accounts, "Most limit left first")
            let view = VStack(spacing: 8) {
                ForEach(AccountListProjection.groups(rows)) { group in
                    AccountListSection(group: group, mode: .switchTask(session), store: store, onChoose: { _ in })
                }
            }.padding(20).frame(width: 660).background(ParityTheme.canvas).environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            XCTAssertGreaterThan(image.height, 200)
            try WindowlessRender.writePNG(image, to:
                directory.appending(path: appearance == .dark ? "task-account-dark.png" : "task-account-light.png"))
        }
    }

    /// With the default login and two accounts sharing its history, the new task's account menu has
    /// Automatic above the accounts, chosen; the composer names the account Automatic picks and why; and
    /// Settings › Accounts has the switch that turns it off. Both appearances, rendered without a window.
    func testNewTaskAccountMenuOffersAutomaticAndTheComposerNamesItsPick() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-automatic-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appending(path: "native")
        try FileManager.default.createDirectory(at: native.appending(path: "projects"), withIntermediateDirectories: true)
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": native.path]
        let now = Date()
        func snapshot(_ email: String, fiveHourUsed: Double, weeklyUsed: Double) -> HarnessAccountSnapshot {
            HarnessAccountSnapshot(id: email, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: email, accountPlan: "Max", detail: "", credentialOwner: "Claude Code", checkedAt: now,
                usage: [AccountUsageMetric(id: "claude:session:", label: "5 hour limit", usedFraction: fiveHourUsed,
                            detail: "\(Int((1 - fiveHourUsed) * 100))% remaining", resetsAt: now.addingTimeInterval(2 * 3600),
                            evidence: .exactQuota, windowMinutes: 300),
                        AccountUsageMetric(id: "claude:weekly:", label: "7 day limit", usedFraction: weeklyUsed,
                            detail: "\(Int((1 - weeklyUsed) * 100))% remaining", resetsAt: now.addingTimeInterval(4 * 86_400),
                            evidence: .exactQuota, windowMinutes: 10_080)],
                canLogin: false, canLogout: true)
        }
        store.publishDefaults([snapshot("personal@example.test", fiveHourUsed: 0.64, weeklyUsed: 0.4)])
        for (name, fiveHour, weekly) in [("work@example.test", 0.12, 0.3), ("side@example.test", 0.82, 0.7)] {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                                                       withDestinationURL: native.appending(path: "projects"))
            let connection = ProviderConnection(id: name, name: name, harness: .claudeCode, providerID: nil,
                                                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            store.publish(snapshot(name, fiveHourUsed: fiveHour, weeklyUsed: weekly), for: connection)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("automatic-account-render")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let model = AppModel(store: SessionStore(sessions: []), runtimeSelections: runtimes, connections: store,
                             restoresIndexOnLaunch: false)
        let preview = try XCTUnwrap(model.newTaskAccountPreview(harness: .claudeCode, model: nil))
        XCTAssertEqual(preview.accountName, "work@example.test", "The account with the most room left")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(name: "yardlet", primaryRoot: folder)
        let draft = NewTaskDraft()
        draft.workspaceURL = folder
        draft.projectID = project.id
        draft.harness = .claudeCode
        draft.text = "Add Automatic to the new task's account menu"

        let directory = try WindowlessRender.directory("claude-account-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            func render(_ view: some View, size: NSSize, name: String) throws -> [WindowlessRender.AccessibilityElement] {
                let host = WindowlessRender.Host(view.environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .top).background(ParityTheme.canvas),
                    size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                return host.accessibilityElements()
            }
            let menu = try render(AccountList(mode: .newTask(.claudeCode), store: store, runtimeSelections: runtimes,
                onChoose: { _ in }, onChooseAutomatic: {}, onAdd: { _ in }, onManage: {}, maxListHeight: 420)
                .padding(16).frame(width: 610), size: NSSize(width: 610, height: 560), name: "new-task-account-menu")
            let automatic = try XCTUnwrap(menu.first { $0.label.hasPrefix(L10n.string("Automatic")) }, "\(menu)")
            XCTAssertEqual(automatic.value, L10n.string("Selected for new tasks"))
            XCTAssertFalse(menu.contains { $0.label.hasPrefix("work@example.test") && $0.value == L10n.string("Selected for new tasks") },
                           "No account is marked while Automatic is chosen")

            let composer = try render(NewTaskHome(recentSessions: [], projects: [project], draft: draft,
                runtimeSelections: runtimes, connections: store,
                accounts: NewTaskAccountSource(preview: { model.newTaskAccountPreview(harness: $0, model: $1) },
                                               pick: { _, _ in nil }),
                onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {}, onCreate: { _ in nil })
                .frame(width: 860, height: 300, alignment: .bottom),
                size: NSSize(width: 860, height: 300), name: "new-task-automatic-line")
            XCTAssertEqual(composer.first { $0.label == L10n.string("Choose account") }?.value, L10n.string("Automatic"))
            // The weekly window decides: its pace to its reset is lower than the five-hour window's.
            let line = "work@example.test · " + L10n.string("Chosen automatically") + " · "
                + L10n.format("%@ %lld%% used", "7 day limit", Int64(30))
            XCTAssertTrue(composer.contains { $0.value.hasPrefix(line) }, "\(composer)")

            _ = try render(AccountList(mode: .manage, store: store, runtimeSelections: runtimes, onChoose: { _ in },
                harnessFilter: .constant(.claudeCode)).padding(16).frame(width: 760),
                size: NSSize(width: 760, height: 620), name: "settings-accounts-automatic")
        }
    }
}
