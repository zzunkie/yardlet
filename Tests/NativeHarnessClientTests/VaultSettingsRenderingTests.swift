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
