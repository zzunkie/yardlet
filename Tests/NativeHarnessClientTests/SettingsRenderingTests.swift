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

    func testAccentPresetsReachSwiftUIAndAppKitInBothAppearances() throws {
        XCTAssertEqual(ParityTheme.accentColor(for: .system), NSColor.controlAccentColor)
        for (preset, light, dark) in [(YardletAccentPreference.ink, 0x143B6B, 0x8CB8FA),
                                      (.grove, 0x14664A, 0x7AD1AD), (.iris, 0x5C45AB, 0xB8A6FA)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let rgb = appearance == .light ? light : dark
                var environment = EnvironmentValues()
                environment.colorScheme = appearance.colorScheme
                environment.yardletAccent = preset
                let native = try XCTUnwrap(NSAppearance(named: appearance.appKitName))
                native.performAsCurrentDrawingAppearance {
                    let resolved = ParityTheme.accent.resolve(in: environment)
                    let bridge = Color(nsColor: ParityTheme.accentColor(for: preset)).resolve(in: environment)
                    XCTAssertEqual(resolved, bridge)
                    XCTAssertEqual(resolved.red, Float(rgb >> 16) / 255, accuracy: 0.001)
                    XCTAssertEqual(resolved.green, Float((rgb >> 8) & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(resolved.blue, Float(rgb & 255) / 255, accuracy: 0.001)
                    let minimum = [ParityTheme.canvas, ParityTheme.sidebar, ParityTheme.elevated, ParityTheme.input]
                        .map { Self.contrast(resolved, $0.resolve(in: environment)) }.min()!
                    XCTAssertGreaterThanOrEqual(minimum, 4.5)
                    XCTAssertGreaterThanOrEqual(Self.contrast(resolved, ParityTheme.onAccent.resolve(in: environment)), 4.5)
                    print("Accent contrast", preset.rawValue, appearance.suffix, String(format: "%.2f", minimum))
                }
            }
        }
    }

    /// The same mounted window picks up a settings write, including a change from one preset to another.
    func testAnOpenWindowFollowsTheAccentSetting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("WindowAccent")))
        defaults.set("light", forKey: YardletPreferenceKeys.appearance)
        let presets: [YardletAccentPreference] = [.ink, .iris, .grove]
        let host = WindowlessRender.Host(YardletWindowPreferences(usesVisualFixture: false) {
            HStack(spacing: 0) {
                ParityTheme.accent
                ForEach(presets) { preset in Color(nsColor: ParityTheme.accentColor(for: preset)) }
            }
        }.defaultAppStorage(defaults), size: CGSize(width: 80, height: 20), appearance: .light, alpha: 0)
        defer { host.close() }
        for (index, preset) in presets.enumerated() {
            defaults.set(preset.rawValue, forKey: YardletPreferenceKeys.accent)
            // Compare two rendered pixels in the same display profile.
            host.settle(until: {
                guard let bitmap = try? host.capture().bitmap else { return false }
                let width = bitmap.pixelsWide / 4
                let y = bitmap.pixelsHigh / 2
                return bitmap.colorAt(x: width / 2, y: y) == bitmap.colorAt(x: width * (index + 1) + width / 2, y: y)
            })
        }
    }

    func testCompletePresetsProvideContrastingColorsInBothAppearances() throws {
        for preset in YardletAccentPreference.allCases where ![.system, .ink, .grove, .iris].contains(preset) {
            let theme = MacColorTheme(preset: preset)
            for mode in ThemeMode.allCases {
                XCTAssertNotNil(preset.colors(in: mode).accent)
                XCTAssertNotNil(theme[mode].background)
                XCTAssertNotNil(theme[mode].text)
            }
            let failures = ThemeContrast.failures(for: theme)
            XCTAssertTrue(failures.isEmpty, "\(preset): \(failures.map(\.message))")
        }
        // Default theme and tinted text contrast adjustment pass 4.5:1 across light and dark modes.
        XCTAssertTrue(ThemeContrast.failures(for: MacColorTheme()).isEmpty)
        for mode in ThemeMode.allCases {
            var env = EnvironmentValues()
            env.colorScheme = mode.scheme
            env.yardletColorTheme = MacColorTheme()
            let bg = ThemeSurface.canvas.resolve(in: env)
            for sample in [Color.orange, Color.green, ParityTheme.accent] {
                let adjusted = ThemeContrast.readableTint(sample, over: bg, in: env).resolve(in: env)
                XCTAssertGreaterThanOrEqual(Self.contrast(adjusted, bg), 4.49, "\(mode): \(sample)")
            }
            for preset in YardletAccentPreference.allCases {
                var buttonEnv = env
                buttonEnv.yardletColorTheme = MacColorTheme(preset: preset)
                let fill = ParityTheme.accentButtonFill.resolve(in: buttonEnv)
                let label = ParityTheme.onAccentButton.resolve(in: buttonEnv)
                XCTAssertGreaterThanOrEqual(Self.contrast(fill, label), 4.49, "\(preset) \(mode) accent button")
                let textColor = (buttonEnv.yardletColorTheme[mode].text?.color ?? .primary).resolve(in: buttonEnv)
                let bubble = ParityTheme.userBubbleFill.resolve(in: buttonEnv)
                let rail = ParityTheme.innerRail.resolve(in: buttonEnv)
                XCTAssertGreaterThanOrEqual(Self.contrast(textColor, bubble), 4.49, "\(preset) \(mode) user bubble")
                XCTAssertGreaterThanOrEqual(Self.contrast(textColor, rail), 4.49, "\(preset) \(mode) inner rail")
                // An unfocused split pane's faded title (`TaskTitleMenu`) on the pane's washed canvas.
                let canvas = ThemeContrast.unfocusedPaneCanvas(in: buttonEnv)
                let alpha = textColor.opacity * Float(ThemeContrast.fadedTextOpacity(0.7, in: buttonEnv))
                let faded = Color.Resolved(red: textColor.red * alpha + canvas.red * (1 - alpha),
                                           green: textColor.green * alpha + canvas.green * (1 - alpha),
                                           blue: textColor.blue * alpha + canvas.blue * (1 - alpha))
                XCTAssertGreaterThanOrEqual(Self.contrast(faded, canvas), 4.49, "\(preset) \(mode) faded pane title")
            }
        }
    }

    func testParityLabelWidthCachesNaturalMeasurementAcrossProposals() {
        final class MeasureProbe: Layout {
            var count = 0
            let natural: CGSize
            init(natural: CGSize) { self.natural = natural }
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                count += 1
                let w = min(natural.width, proposal.width ?? natural.width)
                return CGSize(width: w, height: proposal.height ?? natural.height)
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
        }

        let probe = MeasureProbe(natural: CGSize(width: 64, height: 16))
        let host = WindowlessRender.Host(
            ViewThatFits(in: .horizontal) {
                ParityLabelWidth(limit: 138) {
                    probe { Color.clear }
                }
            }
            .frame(width: 200, height: 24),
            size: CGSize(width: 220, height: 40),
            appearance: .light
        )
        defer { host.close() }
        host.settle()
        // Without caching, ViewThatFits probes (.unspecified, .infinity, concrete width) each measured twice (6+ calls).
        XCTAssertLessThanOrEqual(probe.count, 2, "Expected cached single natural measurement, got \(probe.count)")
    }

    func testThemeProtectsFixedColorsOnTheirDefaultAndCustomBackgrounds() throws {
        var theme = MacColorTheme(preset: .ink)
        XCTAssertTrue(ThemeContrast.failures(for: theme).isEmpty)
        theme.light.background = ThemeRGB("#A0A0A0")
        let failures = ThemeContrast.failures(for: theme)
        let waiting = try XCTUnwrap(failures.first { $0.mode == .light && $0.pair == L10n.string("Waiting line / background") })
        var light = EnvironmentValues()
        light.colorScheme = .light
        let baseline = Self.contrast(Color.orange.resolve(in: light), ParityTheme.originalCanvas.resolve(in: light))
        XCTAssertEqual(waiting.required, min(3, baseline), accuracy: 0.001)
        XCTAssertLessThan(waiting.measured, waiting.required)
        XCTAssertTrue(failures.contains { $0.pair == L10n.string("Diff addition / background") })
        theme.dark.accent = ThemeRGB("#181818")
        XCTAssertTrue(ThemeContrast.failures(for: theme).contains { $0.mode == .dark && $0.required == 3 &&
            $0.pair == L10n.string("Accent / background") })
    }

    func testTheRequestCommandKeepsItsCodeFontWhenTheInterfaceUsesSerif() throws {
        func render(_ theme: MacColorTheme) throws -> Data {
            let bitmap = try WindowlessRender.bitmap(CodexBoundedOutput(text: "swift test --filter LayoutTests", folds: false)
                .frame(width: 320).environment(\.yardletCodeFont, YardletCodeFont(name: "Menlo", points: 14))
                .modifier(MacThemeContent(theme: theme)))
            return try WindowlessRender.pngData(bitmap)
        }
        XCTAssertEqual(try render(MacColorTheme()), try render(MacColorTheme(font: .serif)))
    }

    private static func contrast(_ a: Color.Resolved, _ b: Color.Resolved) -> Float {
        func luminance(_ c: Color.Resolved) -> Float {
            0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
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
    /// "Launch at login" is macOS's login item alone: turned off, nothing of it stays in Yardlet's preferences.
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
        let loginItem = FakeLoginItem()
        let launchAtLogin = LaunchAtLogin(backend: loginItem)

        for appearance in WindowlessRender.Appearance.allCases {
            for (name, height) in [("list-general", 620.0), ("general-headings", 1560.0)] {
                let host = WindowlessRender.Host(SettingsCenterView(size: CGSize(width: 820, height: height),
                    initialSection: SettingsSection.general.rawValue, notificationCenter: QuietNotificationCenter(), connectors: connectors, vault: vault, accounts: accounts,
                    remote: remote, cliUpdates: cliUpdates, instructions: instructions, usage: usage,
                    launchAtLogin: launchAtLogin)
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
                XCTAssertTrue(labels.contains(YardletSetting.launchAtLogin.title), labels.description)
                XCTAssertTrue(labels.contains(YardletSetting.simulator.title), "The Simulator switch is in General")
            }
        }

        let context = YardletSettingsContext(defaults: defaults, launchAtLogin: launchAtLogin)
        let before = Set(defaults.dictionaryRepresentation().keys)
        let added = await YardletSetting.launchAtLogin.set(YardletSetting.on, in: context)
        XCTAssertNil(added)
        XCTAssertEqual(loginItem.registered, true)
        XCTAssertEqual(YardletSetting.launchAtLogin.value(in: context), YardletSetting.on)
        let removed = await YardletSetting.launchAtLogin.set(YardletSetting.off, in: context)
        XCTAssertNil(removed)
        XCTAssertEqual(loginItem.registered, false)
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), before)
        XCTAssertFalse(YardletSetting.launchAtLogin.isShown(in: YardletSettingsContext(defaults: defaults)),
                       "A copy that cannot be a login item has no switch")
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

/// A login item that records what Settings asked of it and never reaches macOS.
private final class FakeLoginItem: LaunchAtLoginBackend, @unchecked Sendable {
    private(set) var registered = false

    func status() async -> LaunchAtLogin.Status { registered ? .on : .off }
    func register() throws { registered = true }
    func unregister() throws { registered = false }
}
