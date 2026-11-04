import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// Settings sections and the Harness Accounts section with remembered, current, unfinished and signed-out
/// readings, the Claude Code and Codex harness pages opened from their rows, and the whole list with
/// General's headings, drawn in an offscreen window (never shown) in both appearances into
/// `.build/settings-qa`.
@MainActor final class SettingsRenderingTests: XCTestCase {
    private let directory = WindowlessRender.repositoryRoot.appending(path: ".build/settings-qa")
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testSettingsSectionsAndTheAccountsSectionDraw() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (store, runtime) = try accountsFixture()
        let context = SettingsAccountsContext(runtimeSelections: runtime, connections: store,
            harnessUsage: AccountHarnessScope.Usage(withTasks: [.codex, .claudeCode], chosenForNewTask: .codex),
            fixtureSnapshots: [])

        // The default list shows the harnesses in use: Muse Code is installed here but unused.
        let groups = AccountGroupProjection.groups(from: store.choices(for: AccountHarnessScope.inUse(
            available: AccountHarnessScope.available(catalog: HarnessCatalog.builtIns.map(\.id),
                installed: [.museCode], savedAccounts: [.claudeCode], signedInDefaults: [.codex]),
            withTasks: [.codex, .claudeCode], savedAccounts: [.claudeCode], chosenForNewTask: .codex)))
        XCTAssertEqual(groups.map(\.identity.displayLabel), ["codex@example.test", "developer@example.test",
            "jordan@example.test", "personal@example.test", "old@example.test"])
        XCTAssertFalse(groups.flatMap(\.harnesses).contains(.museCode))

        let connectors = makeConnectors()
        for appearance in [ColorScheme.light, .dark] {
            let suffix = appearance == .dark ? "dark" : "light"
            for section in SettingsSection.available(hasAccounts: true, hasConnectors: true) {
                let view = SettingsCenterView(initialSection: section.rawValue,
                    notificationCenter: QuietNotificationCenter(), connectors: connectors, accounts: context)
                    .environment(\.colorScheme, appearance)
                try write(try render(view, size: NSSize(width: 820, height: 620)), "\(section.rawValue)-\(suffix).png")
            }
        }

        // Settings › Harnesses › Claude Code and › Codex, opened as a click on their rows opens them.
        // Claude Code's default login is signed out while four saved accounts are connected: the
        // harness reads connected, with the default login on a line of its own. Codex's usage keeps
        // its limits and totals, and its day-by-day history is not listed row by row.
        let signedOut = L10n.string("Default login") + " · " + AccountConnectionPresentation.status(for:
            try XCTUnwrap(store.defaultSnapshots[.claudeCode]))
        for harness in [HarnessKind.claudeCode, .codex] {
            for appearance in WindowlessRender.Appearance.allCases {
                let host = WindowlessRender.Host(SettingsCenterView(initialSection: SettingsSection.harnesses.rawValue,
                    notificationCenter: QuietNotificationCenter(), connectors: connectors, accounts: context)
                    .environment(\.colorScheme, appearance.colorScheme), size: NSSize(width: 820, height: 620),
                    appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressButton(labeled: harness.displayName), harness.displayName)
                await host.settle { host.accessibilityElements().contains { $0.label == L10n.string("Back") } }
                try write(try host.capture().bitmap, "harness-\(harness.rawValue)-\(appearance.suffix).png")
                guard appearance == .light else { continue }
                let elements = host.accessibilityElements()
                let texts = elements.map { "\($0.label) \($0.value)" }
                switch harness {
                case .claudeCode:
                    XCTAssertTrue(elements.contains { $0.label == harness.displayName
                        && $0.value.hasPrefix(L10n.string("Connected")) }, elements.description)
                    XCTAssertTrue(texts.contains { $0.contains(signedOut) }, elements.description)
                default:
                    XCTAssertTrue(texts.contains { $0.contains(L10n.string("Lifetime tokens")) }, elements.description)
                    XCTAssertFalse(texts.contains { $0.contains("2030-01-01") }, elements.description)
                }
            }
        }

        // Codex's default login is being checked again: its row keeps the remembered reading
        // with a spinner, and the refresh button waits.
        let gate = CheckGate()
        store.usesFixtureSnapshots = false
        store.defaultLoader = { descriptor, _ in
            await gate.wait()
            return .unavailable(for: descriptor)
        }
        let check = Task { await store.check(defaultsOf: [.codex], savedOf: [], runtimeSelections: runtime) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !store.isCheckingDefault(.codex), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.isCheckingDefault(.codex))
        for appearance in [ColorScheme.light, .dark] {
            let suffix = appearance == .dark ? "dark" : "light"
            let checking = AccountList(mode: .manage, store: store, runtimeSelections: runtime,
                onChoose: { _ in }, onConnect: { _ in }, onAdd: { _ in },
                harnessUsage: AccountHarnessScope.Usage(withTasks: [.codex, .claudeCode], chosenForNewTask: .codex))
                .padding(.horizontal, 16).padding(.top, 16)
                .frame(width: 629, height: 1180).background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance)
            try write(try render(checking, size: NSSize(width: 629, height: 1180)), "accounts-checking-\(suffix).png")
        }
        store.usesFixtureSnapshots = true
        await gate.open()
        await check.value
    }

    /// Every section the app offers: the Yardlet account above the Personal, Integrations and Harnesses
    /// headings, with General open and its rows under the App, Tasks, Browser and Terminal headings.
    /// `list-general-*.png` is the window's size; `general-headings-*.png` is tall enough for every heading.
    func testTheWholeListAndGeneralsHeadingsDraw() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (store, runtime) = try accountsFixture()
        let accounts = SettingsAccountsContext(runtimeSelections: runtime, connections: store, fixtureSnapshots: [])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("SettingsRenderingTests.list")))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let remote = RemoteControlService(bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            defaults: defaults, environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false)
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([:]), repository: InMemoryVaultRepository(items: []), hmac: MacVault.hmac,
            isAllowedBuild: true, confirm: { _ in true }, defaults: .vaultTests()))
        let root = FileManager.default.temporaryDirectory.appending(path: "settings-list-\(UUID().uuidString)")
        roots.append(root)
        let cliUpdates = CLIUpdateCenter(dependencies: .init(
            runtimes: { [:] }, busyHarnesses: { [] },
            runner: FakeCLIRunner { _ in CLICommandResult(exitCode: 0, stdout: "", stderr: "") }, verifier: FakeVerifier(),
            overrides: CLIRuntimeOverrides(defaults: defaults), defaults: defaults,
            previousVersionsDirectory: root.appending(path: "cli-previous"), environment: [:]))
        let instructions = YardletInstructionsStore(directory: root.appending(path: "instructions"), defaults: defaults)
        let usage = SettingsUsageContext(overview: { TokenUsageFixture.overview() }, isCounting: { true },
                                         limitsCheckedAt: { nil })
        let connectors = makeConnectors()

        for appearance in WindowlessRender.Appearance.allCases {
            for (name, height) in [("list-general", 620.0), ("general-headings", 1560.0)] {
                let host = WindowlessRender.Host(SettingsCenterView(initialSection: SettingsSection.general.rawValue,
                    notificationCenter: QuietNotificationCenter(), connectors: connectors, vault: vault, accounts: accounts,
                    remote: remote, cliUpdates: cliUpdates, instructions: instructions, usage: usage)
                    .environment(\.colorScheme, appearance.colorScheme),
                    size: NSSize(width: 820, height: height), appearance: appearance)
                defer { host.close() }
                host.settle()
                try write(try host.capture().bitmap, "\(name)-\(appearance.suffix).png")
                guard appearance == .light, name == "general-headings" else { continue }
                let labels = host.accessibilityElements().map(\.label)
                XCTAssertTrue(host.accessibilityElements().contains { $0.label == SettingsSection.yardletAccount.title
                    && $0.value == L10n.string("Not signed in") })
                let headings = SettingsSection.Group.allCases.map(\.title) + GeneralSettingsGroup.allCases.map(\.title)
                XCTAssertTrue((headings + SettingsSection.allCases.map(\.title)).allSatisfy(labels.contains),
                              labels.description)
            }
        }
    }

    private func makeConnectors() -> ConnectorCenter {
        ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256,
            clientVersion: "9.9", now: { Date() }))
    }

    /// Codex's default login remembered from an earlier run, and four Claude accounts: one
    /// remembered, one checked now, one whose check could not finish, and one signed out.
    private func accountsFixture() throws -> (ProviderConnectionStore, RuntimeSelectionStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: "settings-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let files = (root.appending(path: "provider-connections.json"),
                     root.appending(path: ProviderConnectionStore.snapshotCacheFileName))
        let earlier = ProviderConnectionStore(fileURL: files.0, snapshotCacheURL: files.1)
        let now = Date()
        var accounts: [String: ProviderConnection] = [:]
        for (email, short, weekly, minutes) in [("developer@example.test", 16.0, 6.0, 12.0),
                                                ("jordan@example.test", 40.0, 100.0, 30.0),
                                                ("personal@example.test", 4.0, 95.0, 125.0),
                                                ("old@example.test", 0.0, 0.0, 300.0)] {
            let home = root.appending(path: email)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let connection = ProviderConnection(id: email, name: email, harness: .claudeCode, providerID: nil,
                homePath: home.path, credentialSelector: nil)
            try earlier.save(connection)
            accounts[email] = connection
            earlier.publish(HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
                state: .signedIn, accountLabel: email, accountPlan: "Claude Max plan", detail: "",
                credentialOwner: "", checkedAt: now.addingTimeInterval(-minutes * 60),
                usage: try claudeUsage(short: short, weekly: weekly), canLogin: false, canLogout: true), for: connection)
        }
        earlier.publishDefaults([
            HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex", state: .signedIn,
                accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "", credentialOwner: "",
                checkedAt: now.addingTimeInterval(-180), usage: try claudeUsage(short: 1, weekly: 12) + [
                    AccountUsageMetric(id: "account-lifetime", label: L10n.string("Lifetime tokens"), usedFraction: nil,
                                       detail: "85,342,602,680", resetsAt: nil, evidence: .accountUsage),
                    AccountUsageMetric(id: HarnessAccountBroker.dailyUsageIDPrefix + "2030-01-01", label: "2030-01-01",
                                       usedFraction: nil, detail: "30,000,000", resetsAt: nil, evidence: .accountUsage),
                ],
                canLogin: false, canLogout: true),
            HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedOut,
                accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now.addingTimeInterval(-180),
                usage: [], canLogin: true, canLogout: false)
        ])

        let store = ProviderConnectionStore(fileURL: files.0, snapshotCacheURL: files.1)
        store.usesFixtureSnapshots = true
        let jordan = try XCTUnwrap(accounts["jordan@example.test"])
        store.publish(HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: jordan.name, accountPlan: "Claude Max plan", detail: "",
            credentialOwner: "", checkedAt: now, usage: try claudeUsage(short: 52, weekly: 100),
            canLogin: false, canLogout: true), for: jordan)
        store.publish(HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .unknown, accountLabel: nil, detail: "timed out", credentialOwner: "", checkedAt: now,
            usage: [], canLogin: true, canLogout: false), for: try XCTUnwrap(accounts["personal@example.test"]))
        store.publish(HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now,
            usage: [], canLogin: true, canLogout: false), for: try XCTUnwrap(accounts["old@example.test"]))
        XCTAssertEqual(store.readingStatus["developer@example.test"], .remembered)
        XCTAssertEqual(store.readingStatus["personal@example.test"], .checkFailed)

        let suite = testDefaultsSuite("yardlet-settings-render")
        let runtime = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            discoversRuntimes: false, loadsPersistedSelections: false)
        runtime.select(URL(filePath: "/usr/bin/true"), for: .museCode)
        return (store, runtime)
    }

    private func claudeUsage(short: Double, weekly: Double) throws -> [AccountUsageMetric] {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":\#(short),"resets_at":"2030-01-01T05:00:00+00:00"},
          {"kind":"weekly_all","group":"weekly","percent":\#(weekly),"resets_at":"2030-01-06T00:00:00+00:00"}]}}
        """#.utf8))
        return try XCTUnwrap(ClaudeUsageProbe.usage(from: response))
    }

    private func render<Content: View>(_ view: Content, size: NSSize) throws -> NSBitmapImageRep {
        let bitmap = try WindowlessRender.hosted(view, size: size).bitmap
        XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 4, from: 4, background: (1, 1)))
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        try WindowlessRender.writePNG(bitmap, to: directory.appending(path: name))
    }
}

private actor CheckGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

private final class QuietNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
