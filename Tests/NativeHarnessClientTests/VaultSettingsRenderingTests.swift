import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Settings → Passwords and the item sheet, drawn offscreen into `.build/vault-qa`, light and dark, from
/// an in-memory vault holding made-up sign-ins. No keychain, Touch ID, browser or window on screen.
///
/// - `settings-vault-*`: the switch and three items (sites, kinds, agent use, last use).
/// - `settings-vault-unsigned-*`: an ad-hoc build with an empty vault: the switch off and disabled.
/// - `vault-item-*`: a saved item's sheet with its previous passwords, recent uses and passkey line.
/// - `vault-item-new-*`: a new item from a page, with its site and username filled in.
/// - `settings-vault-unlinked-*`: codes with no site, with the sites suggested for them and one left to type.
/// - `settings-vault-search-*`: the lists narrowed by a search.
/// - `settings-vault-accounts-*`, `vault-item-account-*`: two accounts of one username, and one's item sheet.
/// - `vault-save-bar-*`: the browser panel's save, update and add-username bars.
/// - `settings-vault-wallet-*`, `vault-card-*`, `vault-address-*`, `vault-wallet-bars-*`: addresses and cards.
/// - `vault-picker-*`, `vault-picker-search-*`, `vault-picker-codes-*`, `vault-picker-empty-*`: the browser panel's
///   key button list on a site's page, searched, searched for a code from the code bar, and on a site with nothing.
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

        let host = WindowlessRender.Host(VaultSettingsView(vault: vault).padding(20)
            .frame(width: 600, height: 520, alignment: .top), size: NSSize(width: 600, height: 520))
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["GitHub (work)", "Vercel", "Example Bank", "github.com", L10n.string("Password manager for agents"),
                     L10n.string("Every time"), L10n.string("While unlocked"), Self.github.kindsTitle,
                     L10n.string("Import CSV…"), L10n.string("Add sign-in"), L10n.string("Delete all passwords…"),
                     L10n.string("Two-factor codes"), L10n.string("Import QR Code…"), L10n.string("Copy Code")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") }, "A secret reached the page: \(spoken)")
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
    func testSearchesAndTheKeyButtonsListDraw() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let fabrikam = VaultItem(name: "Fabrikam", sites: [], username: "ada", hasOneTimeCode: true)
        let northwind = VaultItem(name: "Northwind", sites: ["northwind.test"], username: "ada@example.test", hasOneTimeCode: true)
        let key = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        let vault = vault(items: [Self.github, Self.vercel, Self.bank, fabrikam, northwind])
        for item in [fabrikam, northwind] { try vault.save(item, secret: VaultSecret(oneTimeCode: key)) }

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

        let pickerSize = NSSize(width: 340, height: 400)
        let pickers: [(name: String, origin: String, query: String, codes: Bool, expected: [String])] = [
            ("vault-picker", "https://github.com", "", false, [L10n.format("Saved for %@", "github.com"), "GitHub (work)"]),
            ("vault-picker-search", "https://www.fabrikam.test", "ada", false,
             [L10n.string("Other passwords"), "Example Bank", "Northwind", "Fabrikam"]),
            ("vault-picker-codes", "https://www.fabrikam.test", "ada", true, ["GitHub (work)", "Northwind", "Fabrikam"]),
            ("vault-picker-empty", "https://www.fabrikam.test", "", false,
             [L10n.string("Nothing is saved for this site. Search for a sign-in or code saved elsewhere.")])
        ]
        for picker in pickers {
            let content = VaultPickerView(vault: vault, origin: picker.origin, codes: picker.codes, query: .constant(picker.query),
                                          onPick: { _ in })
                .frame(width: pickerSize.width, height: pickerSize.height, alignment: .top)
            let captures = try WindowlessRender.hostedInBothAppearances(picker.name, in: directory, size: pickerSize) {
                appearance in content.environment(\.colorScheme, appearance.colorScheme).background(.background)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(content, size: pickerSize)
            host.settle()
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            host.close()
            for text in picker.expected { XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(picker.name): no \(text) in \(spoken)") }
            if picker.codes {
                XCTAssertFalse(spoken.contains { $0.contains("Example Bank") || $0.contains("Vercel") }, "A password in the codes: \(spoken)")
            }
            XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") }, "A secret reached the list: \(spoken)")
        }
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

    func testTheItemSheetDraws() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let vault = vault()
        let size = NSSize(width: 520, height: 600)
        let sheet = VaultItemSheet(vault: vault, item: Self.github, onDone: {})
            .frame(width: size.width, height: size.height, alignment: .top)
        let captures = try WindowlessRender.hostedInBothAppearances("vault-item", in: directory, size: size) { appearance in
            sheet.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(sheet, size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Recent use"), L10n.string("Filled"), L10n.string("Refused"), "Fix the release CI",
                     L10n.string("Show a saved password"), L10n.string("Copy Code"), L10n.string("Previous passwords"),
                     L10n.format("%lld kept", Int64(2))] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.contains("not-a-real-password") || $0.contains("an-older-password") },
                       "A password showed unasked: \(spoken)")

        let draft = VaultItemSheet(vault: vault, item: nil, draftSites: ["example.test"], draftUsername: "ada@example.test",
                                   onDone: {})
            .frame(width: size.width, height: 360, alignment: .top)
        try WindowlessRender.hostedInBothAppearances("vault-item-new", in: directory, size: NSSize(width: size.width, height: 360)) {
            appearance in
            draft.environment(\.colorScheme, appearance.colorScheme).background(ParityTheme.canvas)
        }
    }

    /// Two AWS accounts with one IAM username (design §17): the list shows each one's username and account beside its
    /// name, and the item sheet shows the account field under the page's own label.
    func testAccountsOfOneUsernameDraw() throws {
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
    }

    /// The browser panel's save bar (design §17): saving a sign-in, updating one of two accounts of one username (the bar
    /// names it), and adding a username to an item saved without one, which says Save; each closes with its X for now.
    func testTheSaveBarDraws() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let account = [VaultFormField(id: "account", name: "account", label: "Account ID", value: "444455556666")]
        let iam = VaultItem(name: "signin.aws", sites: ["signin.aws"], username: "dev", hasPassword: true, fields: account)
        let blank = VaultItem(name: "example.test", sites: ["example.test"], username: "", hasPassword: true)
        let offers = [
            BrowserVaultSaveOffer(origin: "https://github.com", site: "github.com", username: "ada@example.test",
                                  password: "not-a-real-password", updates: nil),
            BrowserVaultSaveOffer(origin: "https://ap-southeast-2.signin.aws", site: "signin.aws", username: "dev",
                                  password: "not-a-real-password", updates: iam, fields: account),
            BrowserVaultSaveOffer(origin: "https://www.example.test", site: "example.test", username: "ada@example.test",
                                  password: "not-a-real-password", updates: blank, addsAccount: true)
        ]
        let size = NSSize(width: 820, height: 150)
        let bars = VStack(spacing: 0) {
            ForEach(offers.indices, id: \.self) { index in
                BrowserVaultSaveBar(offer: offers[index], neverSave: {}, accept: {}, close: {})
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
        XCTAssertEqual(labels.filter { $0 == L10n.string("Close") }.count, 3, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == L10n.string("Save") }.count, 2, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == L10n.string("Update") }.count, 1, "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("not-a-real-password") }, "\(labels)")
    }

    /// Addresses and cards (design §18): the section in Settings → Passwords with its switch, an address, and cards by
    /// their network or nickname and last four digits, never the number; the card and address sheets; and the browser
    /// panel's bars to save a card or an address and to fill one, or choose among several.
    func testAddressesAndCardsDraw() throws {
        let directory = try WindowlessRender.directory("vault-qa")
        let card = VaultCard(name: "Ada Lovelace", number: "4242424242424242", expiryMonth: 7, expiryYear: 2034)
        let work = VaultCard(number: "5555555555554444", expiryMonth: 1, expiryYear: 2031, nickname: "Work")
        let address = VaultAddress(name: "Ada Lovelace", street: "12 Example Street\nFlat 3", city: "Seoul",
                                   postalCode: "06236", country: "KR", phone: "010-0000-0000")
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(wallet: VaultWallet(addresses: [address], cards: [card, work])),
            repository: InMemoryVaultRepository(items: [Self.github]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
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
    /// adding a second one.
    func testCSVExportsFromBrowsersAndPasswordManagersImport() throws {
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
        XCTAssertEqual(vault.importSignIns(fromChrome + fromBitwarden), 4)
        XCTAssertEqual(vault.items.map(\.name), ["Vercel", "github.com", "Example, Inc.", "Code only"])
        XCTAssertEqual(vault.items.map(\.policy), [.whileUnlocked, .always, .always, .always])
        XCTAssertEqual(vault.items.last.map { [$0.hasPassword, $0.hasOneTimeCode] }, [false, true])
        let vercel = try XCTUnwrap(vault.secret(of: Self.vercel.id))
        XCTAssertEqual(vercel.password, "not-a-real-password")
        XCTAssertEqual(vercel.oneTimeCode?.key, Data("12345678901234567890".utf8))
        XCTAssertEqual(vercel.passkey, Self.passkey, "The saved passkey stays")
    }
}

private final class VaultQuietNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
