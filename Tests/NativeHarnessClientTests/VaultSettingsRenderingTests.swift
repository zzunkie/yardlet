import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Settings → Passwords and the vault's sheets and bars offscreen into `.build/vault-qa`,
/// light and dark, from an in-memory vault without keychain or Touch ID.
@MainActor
final class VaultSettingsRenderingTests: XCTestCase {
    private static let github = VaultItem(
        name: "GitHub (work)", sites: ["github.com"], username: "ada@example.test", hasPassword: true,
        hasOneTimeCode: true, hasPasskey: true, policy: .always, lastUsedAt: Date().addingTimeInterval(-26 * 60 * 60))
    private static let vercel = VaultItem(
        name: "Vercel", sites: ["vercel.com"], username: "ada", hasPasskey: true, policy: .whileUnlocked,
        lastUsedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60))
    private static let bank = VaultItem(
        name: "Example Bank", sites: ["examplebank.test", "http://localhost:3000"], username: "ada",
        hasPassword: true, policy: .everyTime)

    private static let passkey = VaultPasskey(credentialID: "ZmFrZQ==", relyingPartyID: "example.test",
                                              userHandle: "ZmFrZQ==", privateKey: "ZmFrZQ==", signCount: 0)

    private func vault(items: [VaultItem] = [github, vercel, bank], isAllowedBuild: Bool = true) -> VaultCenter {
        let repository = InMemoryVaultRepository(items: items)
        let task = UUID()
        repository.appendUse(VaultUse(at: Date().addingTimeInterval(-26 * 60 * 60), taskID: task, taskTitle: "Fix the release CI",
                                      harness: "claude", itemID: Self.github.id, itemName: Self.github.name,
                                      origin: "https://github.com", kinds: ["login"], outcome: .filled, confirmedBy: .always))
        repository.appendUse(VaultUse(at: Date().addingTimeInterval(-2 * 60 * 60), taskID: task, taskTitle: "Fix the release CI",
                                      harness: "claude", itemID: Self.github.id, itemName: Self.github.name,
                                      origin: "https://github-login.test", kinds: ["login"], outcome: .refused,
                                      reason: "“GitHub (work)” is not saved for github-login.test (it is for github.com), so Yardlet did not fill it."))
        let secrets = InMemoryVaultSecretStore([
            Self.github.id: VaultSecret(password: "not-a-real-password",
                                        oneTimeCode: OneTimeCodeSecret(key: Data("12345678901234567890".utf8)),
                                        passkey: Self.passkey,
                                        previousPasswords: [
                                            VaultPreviousPassword(password: "an-older-password", replacedAt: Date().addingTimeInterval(-3600)),
                                            VaultPreviousPassword(password: "the-oldest-password", replacedAt: Date().addingTimeInterval(-86400))
                                        ]),
            Self.vercel.id: VaultSecret(passkey: Self.passkey),
            Self.bank.id: VaultSecret(password: "not-a-real-password")
        ])
        return VaultCenter(environment: VaultCenter.Environment(
            secrets: secrets, repository: repository, hmac: MacVault.hmac, isAllowedBuild: isAllowedBuild,
            defaults: .vaultTests()))
    }

    func testTheSettingsPageDraws() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let vault = vault()
        let size = NSSize(width: 820, height: 620)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-vault", in: directory, size: size) { appearance in
            SettingsCenterView(size: CGSize(width: size.width, height: size.height),
                               initialSection: SettingsSection.vault.rawValue,
                               notificationCenter: VaultQuietNotificationCenter(), vault: vault)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        // With the browser host, which a test build has not, "Import from Another Browser…" comes first.
        let page = VaultSettingsView(vault: vault, importsFromBrowsers: true).padding(20)
            .frame(width: 600, height: 620, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("settings-vault-browser-import-\(Self.language)", in: directory,
                                                     size: NSSize(width: 600, height: 620)) { appearance in
            page.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        let host = WindowlessRender.Host(page, size: NSSize(width: 600, height: 620))
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["GitHub (work)", "Vercel", "Example Bank", "github.com", L10n.string("Password manager for agents"),
                     L10n.string("Every time"), L10n.string("While unlocked"), Self.github.kindsTitle,
                     L10n.string("Import File…"), L10n.string("Export"), L10n.string("Add sign-in"),
                     L10n.string("Delete all passwords…"),
                     L10n.string("Two-factor codes"), L10n.string("Import QR Code…"), L10n.string("Copy Code"),
                     L10n.string("Import from Another Browser…")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") }, "A secret reached the page: \(spoken)")
    }

    /// The language this run draws in, for the file names.
    private static var language: String { L10n.string("Cancel") == "Cancel" ? "en" : "ko" }

    /// The import sheet (docs/BROWSER_SESSION_ISOLATION.md 10) over made-up Whale and Firefox folders, never a real
    /// browser's: from a task's panel the page's site is chosen first; from Settings none is, and the sheet says the
    /// sign-ins reach new tasks. Both offer the profile's whole visit history, checked as in Chrome's import dialog.
    /// It opens on the default browser: Firefox with its sites, or Chrome, whose folder macOS keeps from Yardlet, with
    /// where to allow Yardlet. Then the browsers it lists and the panel's ⋯ menu, drawn as the system lays out their
    /// items, since a SwiftUI picker or menu builds them only once open.
    func testTheBrowserImportSheetAndMenuDraw() async throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let support = FileManager.default.temporaryDirectory.appending(path: "VaultBrowserImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let now = Date()
        try ChromiumProfileFixture.make(at: support.appending(path: "Naver/Whale"), profiles: [
            .init(folder: "Default", name: "Personal", cookies: ["example.com", "github.com", "naver.com", "notion.so",
                                                                 "vercel.com", "linear.app"].enumerated().map { index, site in
                .init(host: "." + site, name: "session\(index)", value: "made-up")
            }, visits: [.init(url: "https://github.com/", title: "GitHub", date: now.addingTimeInterval(-3600))])
        ], lastUsed: "Default", password: Data("qa-safe-storage-not-real".utf8))
        try FirefoxProfileFixture.make(at: support.appending(path: "Firefox"), profiles: [
            .init(path: "Profiles/qa.default-release", name: "default-release",
                  cookies: [.init(host: ".example.net", name: "session", value: "made-up")],
                  visits: [.init(url: "https://example.net/", date: now.addingTimeInterval(-3600))])
        ], installed: "Profiles/qa.default-release")
        // Chrome's list of profiles exists but cannot be read, as macOS 27 keeps it from apps without Full Disk Access.
        let chrome = support.appending(path: "Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: chrome.appending(path: "Local State"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chrome.appending(path: "Local State").path)

        for (name, request) in [("browser-import-sheet", BrowserLoginImportRequest(site: "example.com")),
                                ("browser-import-sheet-settings", BrowserLoginImportRequest(site: nil, forTask: false))] {
            for appearance in WindowlessRender.Appearance.allCases {
                let sheet = BrowserLoginImportSheet(request: request, applicationSupport: support) { _, _, _ in } onDone: {}
                    defaultBrowser: { "com.naver.Whale" }
                    .environment(\.colorScheme, appearance.colorScheme)
                let host = WindowlessRender.Host(sheet, size: NSSize(width: 520, height: 700), appearance: appearance)
                defer { host.close() }
                // The history's choice shows once the profiles are read; the sites follow, in place of a spinner.
                await host.settle(until: {
                    let elements = host.accessibilityElements()
                    return elements.contains { $0.label.contains(L10n.string("Import visit history")) }
                        && !elements.contains { ["AXProgressIndicator", "AXBusyIndicator"].contains($0.role) }
                })
                host.window.setContentSize(host.hosting.fittingSize)
                host.settle()
                let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
                let history = spoken.first { $0.contains(L10n.string("Import visit history")) } ?? ""
                XCTAssertTrue(history.hasSuffix(" 1"), "the history is checked at first: \(spoken)")
                XCTAssertTrue(spoken.contains { $0.contains(request.forTask
                    ? L10n.string("The sites you choose open signed in, in this task and in new tasks. Their cookies already in Yardlet are replaced.")
                    : L10n.string("The sites you choose open signed in, in new tasks. Their cookies already in Yardlet are replaced.")) },
                              "\(spoken)")
                XCTAssertEqual(spoken.contains { $0.contains(L10n.string("1 site chosen")) }, request.site != nil,
                               "only the page's site is chosen first: \(host.accessibilityElements())")
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(Self.language)-\(appearance.suffix).png"))
            }
        }

        for (name, browser) in [("browser-import-sheet-default-firefox", "org.mozilla.firefox"),
                                ("browser-import-sheet-unreadable-chrome", "com.google.Chrome")] {
            for appearance in WindowlessRender.Appearance.allCases {
                let sheet = BrowserLoginImportSheet(request: BrowserLoginImportRequest(site: nil), applicationSupport: support)
                    { _, _, _ in } onDone: {} defaultBrowser: { browser }
                    .environment(\.colorScheme, appearance.colorScheme)
                let host = WindowlessRender.Host(sheet, size: NSSize(width: 520, height: 700), appearance: appearance)
                defer { host.close() }
                let allow = L10n.string("Open Full Disk Access…")
                // Chrome's lines show once the browsers are read; Firefox's sites follow its profile, in place of a spinner.
                await host.settle(until: {
                    let elements = host.accessibilityElements()
                    return elements.contains { $0.label.contains(browser == "com.google.Chrome" ? allow : L10n.string("Import visit history")) }
                        && !elements.contains { ["AXProgressIndicator", "AXBusyIndicator"].contains($0.role) }
                })
                host.window.setContentSize(host.hosting.fittingSize)
                host.settle()
                let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
                if browser == "com.google.Chrome" {
                    for text in [L10n.format("macOS doesn't let Yardlet read %@'s data until you allow it.", "Chrome"),
                                 L10n.string("Open Files & Folders…"), allow] {
                        XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
                    }
                    XCTAssertFalse(spoken.contains { $0.contains(L10n.string("Search sites")) }, "\(spoken)")
                } else {
                    XCTAssertTrue(spoken.contains { $0.contains("Firefox · default-release") }, "\(spoken)")
                }
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(Self.language)-\(appearance.suffix).png"))
            }
        }

        // The browsers the sheet lists with Chrome the default, each with its app's icon or a globe.
        let choices = BrowserLoginImport.find(in: support, defaultBrowser: "com.google.Chrome").choices
        XCTAssertEqual(choices.map(\.title), ["Chrome", "Whale · Personal", "Firefox · default-release"])
        let items = choices.map { choice in
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.browser.bundleID) {
                item.image = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
            } else {
                item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            }
            item.image?.size = NSSize(width: 16, height: 16)
            return item
        }
        let picker = MenuLine.lines(items)
        let pickerSize = NSSize(width: 300, height: MenuPanel.height(picker) + 40)
        try WindowlessRender.hostedInBothAppearances("browser-import-picker-\(Self.language)", in: directory, size: pickerSize) { appearance in
            MenuPanel(lines: picker, width: 260, highlighted: 0)
                .frame(width: pickerSize.width, height: pickerSize.height)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }

        let viewport = NSMenuItem(title: L10n.string("Viewport"), action: nil, keyEquivalent: "")
        viewport.submenu = NSMenu()
        let lines = MenuLine.lines([viewport, .separator(),
                                    NSMenuItem(title: L10n.string("Import from Another Browser…"), action: nil, keyEquivalent: "")])
        let size = NSSize(width: 300, height: MenuPanel.height(lines) + 40)
        try WindowlessRender.hostedInBothAppearances("browser-panel-menu-\(Self.language)", in: directory, size: size) { appearance in
            MenuPanel(lines: lines, width: 260, highlighted: 2)
                .frame(width: size.width, height: size.height)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    /// Codes an authenticator app brought over with no site (design §14.3): each row holds the site the vault
    /// suggests, from a saved sign-in its name names or its log, for the person to check and link; a code nothing
    /// points to waits for a site to be typed, and linking saves the row's site.
    func testCodesWithNoSiteListTheSitesSuggestedForThem() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let codes = [VaultItem(name: "GitHub", sites: [], username: "ada-codes", hasOneTimeCode: true),
                     VaultItem(name: "Amazon Web Services (root)", sites: [], username: "root", hasOneTimeCode: true),
                     VaultItem(name: "Personal", sites: [], username: "ada", hasOneTimeCode: true)]
        let aws = VaultItem(name: "signin.aws.amazon.com", sites: ["amazon.com"], username: "admin", hasPassword: true)
        let key = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        var secrets = Dictionary(uniqueKeysWithValues: codes.map { ($0.id, VaultSecret(oneTimeCode: key)) })
        secrets[aws.id] = VaultSecret(password: "not-a-real-password")
        secrets[Self.github.id] = VaultSecret(password: "not-a-real-password", oneTimeCode: key)
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(secrets), repository: InMemoryVaultRepository(items: [Self.github, aws] + codes),
            hmac: MacVault.hmac, isAllowedBuild: true, defaults: .vaultTests()))
        let size = NSSize(width: 640, height: 1080)
        let content = VaultSettingsView(vault: vault).padding(20).frame(width: size.width, height: size.height, alignment: .top)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-vault-unlinked", in: directory, size: size) { appearance in
            content.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Two-factor codes with no site"), L10n.string("Link All"), "github.com", "amazon.com",
                     L10n.format("Site for “%@”", "Personal")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertEqual(vault.suggestedSites(for: codes), [codes[0].id: "github.com", codes[1].id: "amazon.com"])
    }

    /// Finding an item (design §16): Settings → Passwords narrows its codes and items to a search, and the key
    /// button's list shows the page's own items, a search over the rest, and the codes alone from the code bar.
    func testSearchesAndTheKeyButtonsListDraw() async throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let fabrikam = VaultItem(name: "Fabrikam", sites: [], username: "ada", hasOneTimeCode: true)
        let northwind = VaultItem(name: "Northwind", sites: ["northwind.test"], username: "ada@example.test", hasOneTimeCode: true)
        let key = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        let vault = vault(items: [Self.github, Self.vercel, Self.bank, fabrikam, northwind])
        for item in [fabrikam, northwind] { try await vault.save(item, secret: VaultSecret(oneTimeCode: key)) }

        let settingsSize = NSSize(width: 640, height: 560)
        let settings = VaultSettingsView(vault: vault, query: "ada git").padding(20)
            .frame(width: settingsSize.width, height: settingsSize.height, alignment: .top)
        let searched = try WindowlessRender.hostedInBothAppearances("settings-vault-search", in: directory, size: settingsSize) {
            appearance in settings.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in searched { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let settingsHost = WindowlessRender.Host(settings, size: settingsSize)
        settingsHost.settle()
        let shown = settingsHost.accessibilityElements().map { "\($0.label) \($0.value)" }
        settingsHost.close()
        XCTAssertTrue(shown.contains { $0.contains("GitHub (work)") }, "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("Example Bank") || $0.contains("Fabrikam") }, "The search let through: \(shown)")

        let pickerSize = NSSize(width: VaultPickerView.width, height: 400)
        let pickers: [(name: String, origin: String, query: String, codes: Bool, expected: [String])] = [
            ("vault-picker", "https://github.com", "", false, [L10n.format("Saved for %@", "github.com"), "GitHub (work)"]),
            ("vault-picker-search", "https://www.fabrikam.test", "ada", false,
             [L10n.string("Other passwords"), "Example Bank", "Northwind", "Fabrikam"]),
            ("vault-picker-codes", "https://www.fabrikam.test", "ada", true, ["GitHub (work)", "Northwind", "Fabrikam"]),
            ("vault-picker-empty", "https://www.fabrikam.test", "", false,
             [L10n.string("Nothing is saved for this site. Search for a sign-in or code saved elsewhere.")])
        ]
        for picker in pickers {
            var filled: [UUID] = []
            var copied: [UUID] = []
            let content = VaultPickerView(vault: vault, origin: picker.origin, kind: picker.codes ? .code : nil,
                                          query: .constant(picker.query),
                                          onPick: { filled.append($0.id) }, onCopyPassword: { copied.append($0.id) })
                .frame(width: pickerSize.width, height: pickerSize.height, alignment: .top)
            let captures = try WindowlessRender.hostedInBothAppearances(picker.name, in: directory, size: pickerSize) {
                appearance in content.environment(\.colorScheme, appearance.colorScheme).background(.background)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(content, size: pickerSize)
            host.settle()
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            let copy = L10n.format("Copy password for %@", Self.github.accountTitle)
            if picker.name == "vault-picker" {
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: copy))
                XCTAssertEqual(copied, [Self.github.id])
                XCTAssertTrue(filled.isEmpty)
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: Self.github.accountTitle))
                XCTAssertEqual(filled, [Self.github.id])
                XCTAssertEqual(copied, [Self.github.id])
            } else if picker.codes {
                XCTAssertFalse(spoken.contains { $0.contains(copy) })
            }
            host.close()
            for text in picker.expected { XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(picker.name): no \(text) in \(spoken)") }
            if picker.codes {
                XCTAssertFalse(spoken.contains { $0.contains("Example Bank") || $0.contains("Vercel") }, "A password in the codes: \(spoken)")
            }
            XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") }, "A secret reached the list: \(spoken)")
        }
    }

    /// The key button's list on a cloud console's sign-in (design §16, §17): one registrable domain holding a root user,
    /// one IAM user name in two accounts, their two-factor codes, an item saved without a username and a shopping
    /// account. A password field lists only the sign-ins and a code field only the codes, each row naming its account
    /// first, what it fills, and what tells it apart (the account ID, the name it was saved under).
    func testTheKeyButtonsListKeepsToTheFieldsKind() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let account = { (value: String) in
            [VaultFormField(id: "account", name: "account", label: "Account ID (12 digits) or account alias", value: value)]
        }
        let items = [
            VaultItem(name: "signin.aws.amazon.com", sites: ["amazon.com"], username: "ops@example.test", hasPassword: true),
            VaultItem(name: "Amazon Web Services", sites: ["amazon.com"], username: "root-account-mfa-device@111122223333",
                      hasOneTimeCode: true),
            VaultItem(name: "ap-northeast-2.signin.aws.amazon.com", sites: ["amazon.com"], username: "notebook",
                      hasPassword: true, lastUsedAt: Date().addingTimeInterval(-3600), fields: account("111122223333")),
            VaultItem(name: "Amazon Web Services", sites: ["amazon.com"], username: "notebook@111122223333", hasOneTimeCode: true),
            VaultItem(name: "ap-northeast-2.signin.aws.amazon.com", sites: ["amazon.com"], username: "notebook",
                      hasPassword: true, fields: account("444455556666")),
            VaultItem(name: "signin.aws.amazon.com", sites: ["signin.aws.amazon.com"], username: "", hasPassword: true),
            VaultItem(name: "amazon.com", sites: ["amazon.com"], username: "ops@example.test", hasPassword: true, hasPasskey: true),
            VaultItem(name: "Amazon Europe", sites: ["amazon.de", "amazon.fr", "amazon.it"], username: "ops@example.test",
                      hasPassword: true),
            VaultItem(name: "Amazon Web Services (notebook@444455556666)", sites: [], username: "notebook@444455556666",
                      hasOneTimeCode: true)
        ]
        let vault = vault(items: [Self.github] + items)
        let size = NSSize(width: VaultPickerView.width, height: 360)
        let lists: [(name: String, query: String, kind: VaultPickerKind?, shown: [String], hidden: [String])] = [
            ("vault-picker-aws-passwords", "", .signIn,
             [L10n.format("Passwords for %@", "signin.aws.amazon.com"), "notebook \(L10n.string("Password")), 111122223333",
              "notebook \(L10n.string("Password")), 444455556666", L10n.string("No username")],
             ["root-account-mfa-device", L10n.string("Verification code")]),
            ("vault-picker-aws-codes", "", .code,
             [L10n.format("Two-factor codes for %@", "signin.aws.amazon.com"),
              "notebook@111122223333 \(L10n.string("Verification code")), Amazon Web Services"],
             ["notebook \(L10n.string("Password"))", "ops@example.test"]),
            ("vault-picker-aws-any", "", nil, [L10n.format("Saved for %@", "signin.aws.amazon.com"), "root-account-mfa-device"], []),
            ("vault-picker-aws-search", "amazon", .signIn,
             [L10n.string("Other passwords"), L10n.format("%@ and %lld more", "amazon.de", Int64(2))], [])
        ]
        for list in lists {
            let content = VaultPickerView(vault: vault, origin: "https://signin.aws.amazon.com", kind: list.kind,
                                          query: .constant(list.query), onPick: { _ in }, onCopyPassword: { _ in })
                .frame(width: size.width, height: size.height, alignment: .top)
            let captures = try WindowlessRender.hostedInBothAppearances(list.name, in: directory, size: size) { appearance in
                content.environment(\.colorScheme, appearance.colorScheme).background(.background)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(content, size: size)
            host.settle()
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            host.close()
            for text in list.shown { XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(list.name): no \(text) in \(spoken)") }
            for text in list.hidden { XCTAssertFalse(spoken.contains { $0.contains(text) }, "\(list.name): \(text) in \(spoken)") }
        }
        // The account used last comes first among the sign-ins.
        XCTAssertEqual(vault.pickerItems(for: "https://signin.aws.amazon.com", matching: "", kind: .signIn).here.first?.id,
                       items[2].id)
    }

    func testAnUnsignedBuildShowsTheVaultOff() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let vault = vault(items: [], isAllowedBuild: false)
        let size = NSSize(width: 600, height: 300)
        let content = VaultSettingsView(vault: vault).padding(20).frame(width: size.width, height: size.height, alignment: .top)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-vault-unsigned", in: directory, size: size) { appearance in
            content.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains(L10n.string("Available in team-signed builds of Yardlet.")) }, "\(spoken)")
    }

    func testTheItemSheetDraws() async throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let vault = vault()
        let size = NSSize(width: 520, height: 600)
        let sheet = VaultItemSheet(vault: vault, item: Self.github, onDone: {})
            .frame(width: size.width, height: size.height, alignment: .top)
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(sheet.environment(\.colorScheme, appearance.colorScheme)
                .background(ParityTheme.canvas), size: size, appearance: appearance)
            defer { host.close() }
            await host.settle(until: {
                host.accessibilityElements().contains { $0.label.contains(L10n.string("Copy Code")) }
            })
            let capture = try host.capture()
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "vault-item-\(appearance.suffix).png"))
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            for text in [L10n.string("Recent use"), L10n.string("Filled"), L10n.string("Refused"), "Fix the release CI",
                         L10n.string("Show a saved password"), L10n.string("Copy Code"), L10n.string("Previous passwords"),
                         L10n.format("%lld kept", Int64(2))] {
                XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
            }
            XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") || $0.contains("an-older-password") },
                           "A password showed unasked: \(spoken)")
        }

        let draft = VaultItemSheet(vault: vault, item: nil, draftSites: ["example.test"], draftUsername: "ada@example.test",
                                   onDone: {})
            .frame(width: size.width, height: 360, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-item-new", in: directory, size: NSSize(width: size.width, height: 360)) {
            appearance in
            draft.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }

        // Remove beside the saved code takes it out on Save, as Apple's Passwords app deletes a verification code: the
        // item keeps its password and passkey, and neither it nor its keychain secret holds a code. An item that holds
        // only its code points to Delete and saves nothing.
        let codeOnly = VaultItem(name: "Fabrikam", sites: [], username: "ada", hasOneTimeCode: true)
        try await vault.save(codeOnly, secret: VaultSecret(oneTimeCode: OneTimeCodeSecret(key: Data("12345678901234567890".utf8))))
        for (name, item, note) in [("vault-item-code-removed", Self.github, "Removed when you save"),
                                   ("vault-item-code-only-removed", codeOnly,
                                    "This item has only its code. Delete it instead.")] {
            for appearance in WindowlessRender.Appearance.allCases {
                var finishedSaving = false
                let removing = WindowlessRender.Host(
                    VaultItemSheet(vault: vault, item: item, onDone: { finishedSaving = true })
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas),
                    size: size, appearance: appearance)
                defer { removing.close() }
                removing.settle()
                try await waitUntil {
                    removing.accessibilityElements().contains { $0.label == L10n.string("Remove") }
                }
                XCTAssertTrue(removing.hosting.pressAccessibilityElement(labelled: L10n.string("Remove")), name)
                removing.settle()
                try WindowlessRender.writePNG(removing.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                let shown = removing.accessibilityElements().map { "\($0.label) \($0.value)" }
                XCTAssertTrue(shown.contains { $0.contains(L10n.string(note)) }, "\(name): \(shown)")
                XCTAssertFalse(shown.contains { $0.contains(L10n.string("Copy Code")) }, "\(name): \(shown)")
                if appearance == .dark {
                    _ = removing.hosting.pressAccessibilityElement(labelled: L10n.string("Save"))
                    if item.id == Self.github.id { try await waitUntil { finishedSaving } }
                }
            }
        }
        let saved = try XCTUnwrap(vault.items.first { $0.id == Self.github.id })
        XCTAssertEqual([saved.hasPassword, saved.hasOneTimeCode, saved.hasPasskey], [true, false, true])
        let stored = await vault.secret(of: Self.github.id)
        let secret = try XCTUnwrap(stored)
        XCTAssertNil(secret.oneTimeCode)
        XCTAssertEqual(secret.password, "not-a-real-password")
        XCTAssertNotNil(secret.passkey)
        XCTAssertEqual(vault.items.first { $0.id == codeOnly.id }?.hasOneTimeCode, true)
        let remaining = await vault.secret(of: codeOnly.id)
        XCTAssertNotNil(remaining?.oneTimeCode)
    }

    /// Two AWS accounts with one IAM username (design §17): the list shows each one's username and account beside its
    /// name, and the item sheet shows the account field under the page's own label.
    func testAccountsOfOneUsernameDraw() async throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let account = { (value: String) in
            [VaultFormField(id: "account", name: "account", label: "Account ID (12 digits) or account alias", value: value)]
        }
        let one = VaultItem(name: "ap-southeast-2.signin.aws.amazon.com", sites: ["amazon.com"], username: "dev",
                            hasPassword: true, fields: account("111122223333"))
        let two = VaultItem(name: "ap-southeast-2.signin.aws.amazon.com", sites: ["amazon.com"], username: "dev",
                            hasPassword: true, fields: account("444455556666"))
        let vault = vault(items: [Self.github, one, two])
        let size = NSSize(width: 640, height: 560)
        let list = VaultSettingsView(vault: vault).padding(20).frame(width: size.width, height: size.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("settings-vault-accounts", in: directory, size: size) { appearance in
            list.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        let host = WindowlessRender.Host(list, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["dev · 111122223333", "dev · 444455556666", "ada@example.test"] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        let sheetSize = NSSize(width: 520, height: 520)
        let sheet = VaultItemSheet(vault: vault, item: two, onDone: {})
            .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-item-account", in: directory, size: sheetSize) { appearance in
            sheet.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }

        // A sign-in that asks for an organization's ID and password in masked fields before the person's own: each is a
        // masked row under the page's label, like the password's, and one left blank keeps its value on Save.
        let business = VaultItem(name: "erp.example.test", sites: ["example.test"], username: "ada", hasPassword: true)
        try await vault.save(business, secret: VaultSecret(password: "not-a-real-password", fields: [
            VaultFormField(id: "orgId", name: "orgId", label: "Organization ID", value: "org-id-not-real"),
            VaultFormField(id: "orgPw", name: "orgPw", label: "Organization password", value: "org-pw-not-real")]))
        let secretSize = NSSize(width: 520, height: 470)
        var finishedSaving = false
        let secretSheet = VaultItemSheet(vault: vault, item: business, onDone: { finishedSaving = true })
            .frame(width: secretSize.width, height: secretSize.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-item-secret-fields", in: directory, size: secretSize) { appearance in
            secretSheet.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        let secretHost = WindowlessRender.Host(secretSheet.environment(\.colorScheme, .light).background(ParityTheme.canvas),
                                               size: secretSize)
        defer { secretHost.close() }
        secretHost.settle()
        try await waitUntil {
            secretHost.accessibilityElements().contains { "\($0.label) \($0.value)".contains("Organization password") }
        }
        let shown = secretHost.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["Organization ID", "Organization password"] {
            XCTAssertTrue(shown.contains { $0.contains(text) }, "No \(text): \(shown)")
        }
        XCTAssertEqual(shown.filter { $0.contains(L10n.string("Show a saved password")) }.count, 3, "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("not-real") }, "A secret showed unasked: \(shown)")
        XCTAssertTrue(secretHost.hosting.pressAccessibilityElement(labelled: L10n.string("Add Secret Field")))
        secretHost.settle()
        try WindowlessRender.writePNG(secretHost.capture().bitmap,
                                      to: directory.appending(path: "vault-item-secret-field-added-light.png"))
        let added = secretHost.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertEqual(added.count, shown.count + 3, "The added row's name, value and minus: \(added)")
        XCTAssertTrue(secretHost.hosting.pressAccessibilityElement(labelled: L10n.string("Save")))
        try await waitUntil { finishedSaving }
        let savedSecret = await vault.secret(of: business.id)
        XCTAssertEqual(savedSecret?.fields?.map(\.value), ["org-id-not-real", "org-pw-not-real"],
                       "Save without a change lost a secret field")
        XCTAssertEqual(savedSecret?.password, "not-a-real-password")
    }

    /// The browser panel's save bar (design §15, §17): saving a sign-in, updating one of two accounts of one username (the
    /// bar names it), adding a username to an item saved without one, which says Save, and a password sent with no
    /// username, which names the item it updates and whose arrow offers the site's other items; each closes with its X.
    func testTheSaveBarDraws() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let account = [VaultFormField(id: "account", name: "account", label: "Account ID", value: "444455556666")]
        let iam = VaultItem(name: "signin.aws", sites: ["signin.aws"], username: "dev", hasPassword: true, fields: account)
        let blank = VaultItem(name: "example.test", sites: ["example.test"], username: "", hasPassword: true)
        let console = VaultItem(name: "Console sign-in", sites: ["example.test"], username: "", hasPassword: true)
        let admin = VaultItem(name: "Console admin", sites: ["example.test"], username: "admin@example.test", hasPassword: true)
        let offers = [
            BrowserVaultSaveOffer(origin: "https://github.com", site: "github.com", username: "ada@example.test",
                                  password: "not-a-real-password", updates: nil),
            BrowserVaultSaveOffer(origin: "https://ap-southeast-2.signin.aws", site: "signin.aws", username: "dev",
                                  password: "not-a-real-password", updates: iam, fields: account),
            BrowserVaultSaveOffer(origin: "https://www.example.test", site: "example.test", username: "ada@example.test",
                                  password: "not-a-real-password", updates: blank, addsAccount: true),
            BrowserVaultSaveOffer(origin: "https://us-east-1.console.example.test", site: "example.test", username: "",
                                  password: "not-a-real-password", updates: console, choices: [console, admin])
        ]
        let size = NSSize(width: 820, height: 200)
        let bars = VStack(spacing: 0) {
            ForEach(offers.indices, id: \.self) { index in
                BrowserVaultSaveBar(offer: offers[index], neverSave: {}, accept: { _ in }, close: {})
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        let captures = try WindowlessRender.hostedInBothAppearances("vault-save-bar", in: directory, size: size) { appearance in
            bars.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(bars, size: size)
        defer { host.close() }
        host.settle()
        let labels = host.accessibilityElements().map(\.label)
        XCTAssertEqual(labels.filter { $0 == L10n.string("Close") }.count, 4, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == L10n.string("Save") }.count, 2, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == L10n.string("Update") }.count, 2, "\(labels)")
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains(L10n.format("Update the saved password of %@ for %@?", "“Console sign-in”",
                                                                "us-east-1.console.example.test")) }, "\(spoken)")
        XCTAssertFalse(labels.contains { $0.contains("not-a-real-password") }, "\(labels)")
    }

    /// The browser panel's setup bar (design §14, §20): a setup the page showed, and the setups an agent's code fill found,
    /// which say that the agent set them up: into a new item, into the account's item, replacing its code, and with the
    /// site's other items on the arrow. Each answers with Not Now and Save, and no bar shows the setup's key.
    func testTheSetupBarSaysWhenTheAgentAsks() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let setup = OneTimeCodeSetup(secret: OneTimeCodeSecret(key: Data("setup-render-key-01".utf8)), issuer: "GitHub",
                                     account: "ada@example.test")
        let signIn = VaultItem(name: "github.com", sites: ["github.com"], username: "ada@example.test", hasPassword: true)
        let other = VaultItem(name: "github.com", sites: ["github.com"], username: "grace@example.test", hasPassword: true)
        let offer = { (target: VaultItem?, choices: [VaultItem], ask: UUID?) in
            BrowserVaultSetupOffer(origin: "https://github.com", site: "github.com", page: "https://github.com/settings/2fa",
                                   setups: [setup], unsupported: 0, target: target, choices: choices, ask: ask)
        }
        let offers = [
            offer(signIn, [signIn], nil),
            offer(nil, [], UUID()),
            offer(signIn, [signIn], UUID()),
            offer(Self.github, [Self.github], UUID()),
            offer(signIn, [signIn, other], UUID())
        ]
        let size = NSSize(width: 760, height: 230)
        let bars = VStack(spacing: 0) {
            ForEach(offers.indices, id: \.self) { index in
                BrowserVaultSetupBar(offer: offers[index], dismiss: {}, accept: { _ in })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        let captures = try WindowlessRender.hostedInBothAppearances("vault-setup-bar", in: directory, size: size) { appearance in
            bars.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(bars, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.format("Save the two-factor code for %@ in “%@”?", "github.com", "github.com"),
                     L10n.format("Save the two-factor code the agent set up for %@?", "github.com"),
                     L10n.format("Save the two-factor code the agent set up for %@ in “%@”?", "github.com", "github.com"),
                     L10n.format("Replace the two-factor code in “%@” with the one the agent set up?", "GitHub (work)")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        let labels = host.accessibilityElements().map(\.label)
        XCTAssertEqual(labels.filter { $0 == L10n.string("Not Now") }.count, 5, "\(labels)")
        XCTAssertFalse(spoken.contains { $0.contains(Base32.encode(setup.secret.key)) }, "\(spoken)")
    }

    /// Addresses and cards (design §18): the section in Settings → Passwords with its switch, an address, and cards by
    /// their network or nickname and last four digits, never the number; the card and address sheets; and the browser
    /// panel's bars to save a card or an address and to fill one, or choose among several.
    func testAddressesAndCardsDraw() async throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let card = VaultCard(name: "Ada Lovelace", number: "4242424242424242", expiryMonth: 7, expiryYear: 2034)
        let work = VaultCard(number: "5555555555554444", expiryMonth: 1, expiryYear: 2031, nickname: "Work")
        let address = VaultAddress(name: "Ada Lovelace", street: "12 Example Street\nFlat 3", city: "Seoul",
                                   postalCode: "06236", country: "KR", phone: "010-0000-0000")
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(wallet: VaultWallet(addresses: [address], cards: [card, work])),
            repository: InMemoryVaultRepository(items: [Self.github]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        _ = await vault.loadWallet()
        let size = NSSize(width: 640, height: 340)
        let section = VaultWalletSection(vault: vault).padding(20).frame(width: size.width, height: size.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("settings-vault-wallet", in: directory, size: size) { appearance in
            section.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        let host = WindowlessRender.Host(section, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["Visa •••• 4242", "Work •••• 4444", "Ada Lovelace", L10n.string("Save and fill addresses and cards")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.contains("4242424242424242") || $0.contains("5555555555554444") },
                       "A card number showed: \(spoken)")

        let cardSize = NSSize(width: 480, height: 300)
        let cardSheet = VaultCardSheet(vault: vault, card: card, onDone: {})
            .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-card", in: directory, size: cardSize) { appearance in
            cardSheet.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        let addressSize = NSSize(width: 480, height: 520)
        let addressSheet = VaultAddressSheet(vault: vault, address: address, onDone: {})
            .frame(width: addressSize.width, height: addressSize.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-address", in: directory, size: addressSize) { appearance in
            addressSheet.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }

        let barsSize = NSSize(width: 820, height: 250)
        let bars = VStack(spacing: 0) {
            BrowserWalletSaveBar(offer: BrowserWalletSaveOffer(card: card), accept: {}, close: {})
            BrowserWalletSaveBar(offer: BrowserWalletSaveOffer(address: address), accept: {}, close: {})
            BrowserWalletFillBar(offer: BrowserWalletFillOffer(which: .card, page: ""), wallet: VaultWallet(cards: [card]),
                                 fillAddress: { _ in }, fillCard: { _ in }, dismiss: {})
            BrowserWalletFillBar(offer: BrowserWalletFillOffer(which: .address, page: ""), wallet: vault.wallet,
                                 fillAddress: { _ in }, fillCard: { _ in }, dismiss: {})
            BrowserWalletFillBar(offer: BrowserWalletFillOffer(which: .card, page: ""), wallet: vault.wallet,
                                 fillAddress: { _ in }, fillCard: { _ in }, dismiss: {})
        }
        .frame(width: barsSize.width, height: barsSize.height, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-wallet-bars", in: directory, size: barsSize) { appearance in
            bars.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
    }

    /// Chrome's and Bitwarden's exports: columns found by name in any order, a quoted name with a
    /// comma, a doubled quote and a line break in a note, Bitwarden's two-factor codes; rows without a
    /// site or without a password or code left out. Importing again updates the saved item rather than
    /// adding a second one. Then Yardlet's own export (design §8.1), which its import reads back.
    func testCSVExportsFromBrowsersAndPasswordManagersImportAndYardletsOwnExportRoundTrips() async throws {
        let chrome = """
        name,url,username,password,note\r
        github.com,https://www.github.com/login,ada@example.test,not-a-real-password,"two\r
        lines"\r
        app,android://abc@com.example.app/,ada,not-a-real-password,\r
        empty,https://example.org,ada,,\r

        """
        let bitwarden = #"""
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        ,,login,"Example, Inc.","say ""hi""",,0,"https://accounts.example.co.uk/signin,https://example.com",ada,"not-a-""real""-password",
        ,1,login,Vercel,,,0,vercel.com,ada,not-a-real-password,otpauth://totp/Vercel:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
        ,,login,Code only,,,0,example.org,grace,,JBSWY3DPEHPK3PXP
        """#
        XCTAssertEqual(VaultCSVImport.records("a,\"b,c\",\"d \"\"e\"\"\"\n\n1,2,3"), [["a", "b,c", "d \"e\""], ["1", "2", "3"]])

        let fromChrome = VaultCSVImport.entries(chrome)
        XCTAssertEqual(fromChrome, [VaultCSVImport.Entry(name: "github.com", sites: ["github.com"], username: "ada@example.test",
                                                         password: "not-a-real-password")])
        let fromBitwarden = VaultCSVImport.entries(bitwarden)
        XCTAssertEqual(fromBitwarden, [
            VaultCSVImport.Entry(name: "Example, Inc.", sites: ["example.co.uk", "example.com"], username: "ada",
                                 password: "not-a-\"real\"-password"),
            VaultCSVImport.Entry(name: "Vercel", sites: ["vercel.com"], username: "ada", password: "not-a-real-password",
                                 oneTimeCode: OneTimeCodeSecret(key: Data("12345678901234567890".utf8))),
            VaultCSVImport.Entry(name: "Code only", sites: ["example.org"], username: "grace", password: "",
                                 oneTimeCode: OneTimeCodeSecret(setupText: "JBSWY3DPEHPK3PXP"))
        ])

        let vault = vault(items: [Self.vercel])
        let imported = await vault.importSignIns(fromChrome + fromBitwarden)
        XCTAssertEqual(imported, 4)
        XCTAssertEqual(vault.items.map(\.name), ["Vercel", "github.com", "Example, Inc.", "Code only"])
        XCTAssertEqual(vault.items.map(\.policy), [.whileUnlocked, .always, .always, .always])
        XCTAssertEqual(vault.items.last.map { [$0.hasPassword, $0.hasOneTimeCode] }, [false, true])
        let stored = await vault.secret(of: Self.vercel.id)
        let vercel = try XCTUnwrap(stored)
        XCTAssertEqual(vercel.password, "not-a-real-password")
        XCTAssertEqual(vercel.oneTimeCode?.key, Data("12345678901234567890".utf8))
        XCTAssertEqual(vercel.passkey, Self.passkey, "The saved passkey stays")

        // Yardlet's export: Apple Passwords' columns, which Chrome, Bitwarden and 1Password import too; a row for each
        // site of a sign-in, its other fields in the notes; a code with no site in a row with no address; a passkey
        // alone left out, and an item the keychain did not give counted; a comma and a quote with a combining mark
        // still quoted. One confirmation reads every item, the one an agent may use only after Touch ID too; without
        // it no file is chosen, and without a file nothing is written. The file replaces one already there, only its
        // owner may read it, its folder keeps its own mode, and nothing else is left beside it.
        let bank = VaultItem(name: "Example, \"Bank\"", sites: ["examplebank.test", "http://localhost:3000"],
                             username: "+82 10-0000-0000", hasPassword: true, policy: .everyTime,
                             fields: [VaultFormField(id: "account", name: "", label: "Account ID", value: "123456789012")])
        let codeOnly = VaultItem(name: "Example Code", sites: [], username: "grace", hasOneTimeCode: true)
        let eightDigits = OneTimeCodeSecret(key: Data("an-eight-digit-key!!".utf8), digits: 8, period: 60, algorithm: .sha256)
        let githubCode = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        let bankPassword = "not,a \"real\"\npassword,\u{301}x\"\u{301}"
        var answer = false
        var reasons: [String] = []
        let source = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([
                Self.github.id: VaultSecret(password: "not-a-real-password", oneTimeCode: githubCode, passkey: Self.passkey),
                Self.vercel.id: VaultSecret(passkey: Self.passkey),
                bank.id: VaultSecret(password: bankPassword,
                                     fields: [VaultFormField(id: "org", name: "", label: "Organization password",
                                                             value: "not-a-real-secret")]),
                codeOnly.id: VaultSecret(oneTimeCode: eightDigits)
            ]),
            repository: InMemoryVaultRepository(items: [Self.github, Self.vercel, bank, codeOnly, Self.bank]),
            hmac: MacVault.hmac, isAllowedBuild: true, confirm: { reasons.append($0); return answer },
            defaults: .vaultTests()))
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Yardlet Passwords.csv")
        try Data("an older export".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var chosen = 0
        let refused = try await source.exportSignIns { chosen += 1; return file }
        XCTAssertNil(refused)
        XCTAssertEqual(chosen, 0, "no file is chosen before the person confirms")
        answer = true
        let unchosen = try await source.exportSignIns { nil }
        XCTAssertNil(unchosen)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "an older export")
        let written = try await source.exportSignIns { file }
        let export = try XCTUnwrap(written)
        let exportReason = L10n.string("export all saved passwords to a file")
        XCTAssertEqual(reasons, [exportReason, exportReason, exportReason])
        XCTAssertEqual(export, VaultCenter.SignInExport(count: 3, unreadable: 1))
        func mode(_ url: URL) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(folder), 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Yardlet Passwords.csv"])
        let text = try String(contentsOf: file, encoding: .utf8)
        let githubAuth = "otpauth://totp/GitHub%20%28work%29:ada%40example.test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            + "&issuer=GitHub%20%28work%29&algorithm=SHA1&digits=6&period=30"
        let codeAuth = "otpauth://totp/Example%20Code:grace?secret=\(Base32.encode(eightDigits.key))&issuer=Example%20Code"
            + "&algorithm=SHA256&digits=8&period=60"
        let bankNotes = "Account ID: 123456789012\nOrganization password: not-a-real-secret"
        XCTAssertTrue(text.hasPrefix("Title,URL,Username,Password,Notes,OTPAuth\r\n"))
        XCTAssertEqual(VaultCSVImport.records(text), [
            VaultCSVExport.header,
            ["GitHub (work)", "https://github.com/", "ada@example.test", "not-a-real-password", "", githubAuth],
            ["Example, \"Bank\"", "https://examplebank.test/", "+82 10-0000-0000", bankPassword, bankNotes, ""],
            ["Example, \"Bank\"", "http://localhost:3000/", "+82 10-0000-0000", bankPassword, bankNotes, ""],
            ["Example Code", "", "grace", "", "", codeAuth]
        ])
        let marked = VaultCSVExport.Row(title: "a,\u{301}b", url: "", username: "", password: "c\"\u{301}d", notes: "", otpAuth: "")
        XCTAssertEqual(VaultCSVImport.records(VaultCSVExport.text([marked])).last, marked.fields)

        // Import CSV brings each item back whole, once: importing the file again adds nothing. Rows of the same
        // sign-in apart from each other stay two items.
        let returned = self.vault(items: [])
        let entries = VaultCSVImport.entries(text)
        let importedCount = await returned.importSignIns(entries)
        XCTAssertEqual(importedCount, 3)
        XCTAssertEqual(returned.items.map(\.name), ["GitHub (work)", "Example, \"Bank\"", "Example Code"])
        XCTAssertEqual(returned.items.map(\.sites), [["github.com"], ["examplebank.test", "http://localhost:3000"], []])
        XCTAssertEqual(returned.items.map(\.username), ["ada@example.test", "+82 10-0000-0000", "grace"])
        var secrets: [VaultSecret?] = []
        for item in returned.items { secrets.append(await returned.secret(of: item.id)) }
        XCTAssertEqual(secrets.map { $0?.password }, ["not-a-real-password", bankPassword, nil])
        XCTAssertEqual(secrets.map { $0?.oneTimeCode }, [githubCode, nil, eightDigits])
        let updatedCount = await returned.importSignIns(entries)
        XCTAssertEqual(updatedCount, 2)
        XCTAssertEqual(returned.items.count, 3)
        let apart = "Title,URL,Username,Password\nLogin,https://a.example,ada,same\nOther,https://c.example,ada,x\n"
            + "Login,https://b.example,ada,same\n"
        XCTAssertEqual(VaultCSVImport.entries(apart).map(\.sites), [["a.example"], ["c.example"], ["b.example"]])
    }

    /// Yardlet's encrypted backup (design §8.1): nothing is chosen or read before the person confirms; the file is the
    /// owner's alone and holds nothing in the clear; only its own key opens it, typed in any case with spaces, and a
    /// changed file opens with none. A restore replaces nothing: a saved item keeps its password and agent use, takes
    /// the code it lacked and keeps the backup's other password among its previous ones; the rest come back with
    /// their agent use and previous passwords; each item whose passkey stayed behind is named; restoring again adds
    /// nothing. Then the key's sheet and the prompt for it, and the Export menu.
    func testAnEncryptedBackupOpensOnlyWithItsKeyAndRestoresWithoutReplacing() async throws {
        let codeOnly = VaultItem(name: "Example Code", sites: [], username: "grace", hasOneTimeCode: true)
        let githubCode = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        let eightDigits = OneTimeCodeSecret(key: Data("an-eight-digit-key!!".utf8), digits: 8, period: 60, algorithm: .sha256)
        let older = VaultPreviousPassword(password: "an-older-password", replacedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let address = VaultAddress(name: "Ada Lovelace", street: "12 Example Street", city: "Seoul", country: "KR")
        let card = VaultCard(name: "Ada Lovelace", number: "4242424242424242", expiryMonth: 7, expiryYear: 2034)
        var answer = false
        var reasons: [String] = []
        let source = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([
                Self.github.id: VaultSecret(password: "not-a-real-password", oneTimeCode: githubCode, passkey: Self.passkey,
                                            previousPasswords: [older]),
                Self.vercel.id: VaultSecret(passkey: Self.passkey),
                Self.bank.id: VaultSecret(password: "not-a-real-bank-password"),
                codeOnly.id: VaultSecret(oneTimeCode: eightDigits)
            ], wallet: VaultWallet(addresses: [address], cards: [card])),
            repository: InMemoryVaultRepository(items: [Self.github, Self.vercel, Self.bank, codeOnly]),
            hmac: MacVault.hmac, isAllowedBuild: true, confirm: { reasons.append($0); return answer },
            defaults: .vaultTests()))
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Yardlet Passwords Backup.\(VaultBackup.fileExtension)")
        var chosen = 0
        let refused = try await source.exportBackup { _ in chosen += 1; return (file, true) }
        XCTAssertNil(refused)
        XCTAssertEqual(chosen, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        answer = true
        var offered: Bool?
        let written = try await source.exportBackup { offersWallet in offered = offersWallet; return (file, true) }
        let export = try XCTUnwrap(written)
        XCTAssertEqual(reasons, Array(repeating: L10n.string("back up all saved passwords to an encrypted file"), count: 2))
        XCTAssertEqual(offered, true)
        XCTAssertEqual([export.count, export.unreadable], [3, 0])
        XCTAssertNotNil(export.recoveryKey.range(of: #"^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){5}$"#,
                                                 options: .regularExpression), export.recoveryKey)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for clear in ["not-a-real-password", "not-a-real-bank-password", "an-older-password", "Example Bank", "github.com",
                      "4242424242424242", "Seoul", Base32.encode(githubCode.key), export.recoveryKey] {
            XCTAssertFalse(text.contains(clear), "\(clear) is in the clear")
        }
        XCTAssertTrue(VaultBackup.isBackup(data))
        XCTAssertFalse(VaultBackup.isBackup(Data("Title,URL,Username,Password\n".utf8)))

        let other = try XCTUnwrap(VaultBackup.makeRecoveryKey(randomBytes: VaultPasswordGenerator.systemRandomBytes))
        XCTAssertThrowsError(try VaultBackup.open(data, recoveryKey: other)) { XCTAssertEqual($0 as? VaultBackup.Failure, .wrongKey) }
        var changed = data
        changed[changed.count / 2] ^= 1
        XCTAssertThrowsError(try VaultBackup.open(changed, recoveryKey: export.recoveryKey))
        XCTAssertThrowsError(try VaultBackup.open(Data("not a backup".utf8), recoveryKey: export.recoveryKey)) {
            XCTAssertEqual($0 as? VaultBackup.Failure, .notABackup)
        }
        let typed = export.recoveryKey.lowercased().replacingOccurrences(of: "-", with: " ")
        let contents = try VaultBackup.open(data, recoveryKey: typed)
        XCTAssertEqual(contents.items.map(\.name), ["GitHub (work)", "Vercel", "Example Bank", "Example Code"])
        XCTAssertEqual(contents.items.map(\.hadPasskey), [true, true, false, false])
        XCTAssertEqual(contents.wallet, VaultWallet(addresses: [address], cards: [card]))

        // A saved GitHub sign-in with a newer password and no code.
        let saved = VaultItem(name: "GitHub", sites: ["github.com"], username: "ada@example.test", hasPassword: true,
                              policy: .whileUnlocked)
        let target = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([saved.id: VaultSecret(password: "a-newer-password")]),
            repository: InMemoryVaultRepository(items: [saved]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        let restored = await target.restoreBackup(contents)
        XCTAssertEqual(restored, VaultCenter.BackupRestore(count: 3, walletCount: 2,
                                                           passkeys: ["GitHub (work) · github.com", "Vercel · vercel.com"]))
        XCTAssertEqual(target.items.map(\.name), ["GitHub", "Example Bank", "Example Code"])
        XCTAssertEqual(target.items.map(\.policy), [.whileUnlocked, .everyTime, .always])
        XCTAssertEqual(target.items.map(\.sites), [["github.com"], ["examplebank.test", "http://localhost:3000"], []])
        let stored = await target.secret(of: saved.id)
        let github = try XCTUnwrap(stored)
        XCTAssertEqual(github.password, "a-newer-password")
        XCTAssertEqual(github.oneTimeCode, githubCode)
        XCTAssertEqual(github.previousPasswords?.map(\.password), ["not-a-real-password"])
        XCTAssertNil(github.passkey)
        let bank = try XCTUnwrap(target.items.first { $0.name == "Example Bank" })
        let bankSecret = await target.secret(of: bank.id)
        XCTAssertEqual(bankSecret?.password, "not-a-real-bank-password")
        let lastID = try XCTUnwrap(target.items.last?.id)
        let lastSecret = await target.secret(of: lastID)
        XCTAssertEqual(lastSecret?.oneTimeCode, eightDigits)
        XCTAssertEqual(target.wallet.addresses.map(\.street), ["12 Example Street"])
        XCTAssertEqual(target.wallet.cards.map(\.number), ["4242424242424242"])
        let repeated = await target.restoreBackup(contents)
        XCTAssertEqual(repeated.count, 0)
        XCTAssertEqual(repeated.walletCount, 0)
        XCTAssertEqual(target.items.count, 3)

        // An item whose sites changed outside Yardlet takes nothing from a backup or a CSV, and keeps what the keychain
        // saved with it; a file's site no page could match brings nothing.
        let tampered = VaultItem(name: "Bank", sites: ["examplebank.test", "evil.example"], username: "ada", hasPassword: true)
        var kept = VaultSecret(password: "a-saved-password")
        kept.savedSites = ["examplebank.test"]
        kept.savedPolicy = .always
        let guarded = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([tampered.id: kept]), repository: InMemoryVaultRepository(items: [tampered]),
            hmac: MacVault.hmac, isAllowedBuild: true, defaults: .vaultTests()))
        let restoredCount = await guarded.restoreBackup(contents)
        XCTAssertEqual(restoredCount.count, 2)
        let importedCount = await guarded.importSignIns(VaultCSVImport.entries("name,url,username,password\nBank,https://examplebank.test,ada,new\n"))
        XCTAssertEqual(importedCount, 0)
        let retained = await guarded.secret(of: tampered.id)
        XCTAssertEqual(retained, kept)
        let crafted = VaultBackup.Contents(items: [.init(name: "Wide", sites: ["com", "http://example.com"], username: "x",
                                                         policy: .always, createdAt: Date(), password: "p", hadPasskey: false)])
        let rejected = await guarded.restoreBackup(crafted)
        XCTAssertEqual(rejected.count, 0)
        XCTAssertFalse(guarded.items.contains { $0.name == "Wide" })

        let directory = try WindowlessRender.directory("vault-qa")
        let shown = VaultCenter.BackupExport(recoveryKey: "7K3QD-M9VXA-2B8RT-C4HZN-0PW6E-JS1YF", count: 3, unreadable: 0)
        try WindowlessRender.hostedInBothAppearances("vault-backup-key-\(Self.language)", in: directory,
                                                     size: NSSize(width: 480, height: 300)) { appearance in
            VaultRecoveryKeySheet(export: shown) {}.environment(\.colorScheme, appearance.colorScheme)
        }
        try WindowlessRender.hostedInBothAppearances("vault-backup-import-\(Self.language)", in: directory,
                                                     size: NSSize(width: 480, height: 230)) { appearance in
            VaultBackupKeySheet(fileName: file.lastPathComponent, onImport: { _ in nil }, onCancel: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let lines = MenuLine.lines([NSMenuItem(title: L10n.string("Encrypted Backup…"), action: nil, keyEquivalent: ""),
                                    NSMenuItem(title: L10n.string("CSV for Another Password Manager…"), action: nil,
                                               keyEquivalent: "")])
        let size = NSSize(width: 320, height: MenuPanel.height(lines) + 40)
        try WindowlessRender.hostedInBothAppearances("vault-export-menu-\(Self.language)", in: directory, size: size) { appearance in
            MenuPanel(lines: lines, width: 280, highlighted: 0)
                .frame(width: size.width, height: size.height)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }
}

private final class VaultQuietNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
