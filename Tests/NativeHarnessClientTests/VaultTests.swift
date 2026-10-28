import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import NativeHarnessClient

/// The vault's contracts that would break without a visible sign (docs/BROWSER_VAULT_DESIGN.md):
/// which pages an item's sites cover, the RFC 6238 codes, the refusal of an item asked for on
/// another site, the codes an authenticator app's export brings over, how such a code with no site
/// comes to fill on its site, and the passwords it makes.
@MainActor
final class VaultTests: XCTestCase {
    func testSitesCoverTheirSubdomainsOverHTTPSAndNothingThatOnlyLooksAlike() {
        let suffixes = PublicSuffixList.bundled
        XCTAssertEqual(VaultSite.suggestion(for: "https://www.github.com/login", suffixes: suffixes), "github.com")
        XCTAssertEqual(VaultSite.suggestion(for: "https://accounts.example.co.uk/x", suffixes: suffixes), "example.co.uk")
        // A site anyone can register under is not one person's site.
        XCTAssertEqual(VaultSite.suggestion(for: "https://alice.github.io/", suffixes: suffixes), "alice.github.io")
        XCTAssertNil(VaultSite.normalize("github.io", suffixes: suffixes))
        XCTAssertNil(VaultSite.normalize("com", suffixes: suffixes))
        XCTAssertNil(VaultSite.normalize("http://github.com", suffixes: suffixes))
        XCTAssertEqual(VaultSite.normalize("http://localhost:3000/login", suffixes: suffixes), "http://localhost:3000")

        for page in ["https://github.com", "https://www.github.com", "https://gist.github.com:443"] {
            XCTAssertTrue(VaultSite.matches("github.com", origin: page), page)
        }
        for page in ["http://github.com", "https://github-login.com", "https://evilgithub.com", "https://github.com.evil.io"] {
            XCTAssertFalse(VaultSite.matches("github.com", origin: page), page)
        }
        XCTAssertTrue(VaultSite.matches("http://localhost:3000", origin: "http://localhost:3000"))
        XCTAssertFalse(VaultSite.matches("http://localhost:3000", origin: "http://localhost:3001"))
        // An address is one host, not a domain whose last parts other addresses share.
        XCTAssertEqual(VaultSite.suggestion(for: "https://192.168.1.1/login", suffixes: suffixes), "192.168.1.1")
        XCTAssertEqual(VaultSite.suggestion(for: "https://10.0.0.1:8443", suffixes: suffixes), "10.0.0.1")
        XCTAssertTrue(VaultSite.matches("192.168.1.1", origin: "https://192.168.1.1"))
        XCTAssertFalse(VaultSite.matches("1.1", origin: "https://45.33.1.1"))
        XCTAssertFalse(VaultSite.matches("192.168.1.1", origin: "https://10.192.168.1.1"))
    }

    func testOneTimeCodesMatchRFC6238() throws {
        let key = Data("12345678901234567890".utf8)
        XCTAssertEqual(OneTimeCodeSecret(setupText: "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")?.key, key)
        let secret = OneTimeCodeSecret(key: key, digits: 8)
        XCTAssertEqual(OneTimeCode.code(for: secret, at: Date(timeIntervalSince1970: 59), hmac: MacVault.hmac), "94287082")
        XCTAssertEqual(OneTimeCode.code(for: secret, at: Date(timeIntervalSince1970: 1_111_111_109), hmac: MacVault.hmac),
                       "07081804")
        let fromAddress = try XCTUnwrap(OneTimeCodeSecret(
            setupText: "otpauth://totp/Example:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&issuer=Example"))
        XCTAssertEqual(fromAddress, secret)
    }

    /// Google Authenticator's export (Transfer accounts: `otpauth-migration://`, protobuf), read from a
    /// picture with Vision: each time-based account becomes an item of its own with no site or password,
    /// a counter-based one is counted and left out, and importing again adds nothing. A site's setup
    /// address gives the same code as the export's account for it.
    func testAuthenticatorExportsBecomeItemsOfTheirOwn() throws {
        func varint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return bytes
        }
        func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(bytes.count) + bytes }
        func field(_ number: Int, _ value: Int) -> [UInt8] { varint(number << 3) + varint(value) }
        func account(_ key: String, _ name: String, _ issuer: String, algorithm: Int, digits: Int, type: Int) -> [UInt8] {
            field(1, Array(key.utf8)) + field(2, Array(name.utf8)) + field(3, Array(issuer.utf8))
                + field(4, algorithm) + field(5, digits) + field(6, type)
        }
        let payload = field(1, account("12345678901234567890", "ada@example.test", "Example", algorithm: 1, digits: 1, type: 2))
            + field(1, account("another-test-key-000", "Second:grace@example.test", "", algorithm: 2, digits: 2, type: 2))
            + field(1, account("counter-test-key-000", "hotp@example.test", "Counter", algorithm: 1, digits: 1, type: 1))
            + field(2, 1)
        let export = "otpauth-migration://offline?data="
            + Data(payload).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(export.utf8)
        let picture = try XCTUnwrap(generator.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let png = try XCTUnwrap(NSBitmapImageRep(ciImage: picture).representation(using: .png, properties: [:]))
        let found = VaultQRCodeReader.setups(in: VaultQRCodeReader.messages(in: png))
        XCTAssertEqual(found.unsupported, 1)
        XCTAssertEqual(found.setups.map(\.issuer), ["Example", "Second"])
        XCTAssertEqual(found.setups.map(\.account), ["ada@example.test", "grace@example.test"])
        XCTAssertEqual(found.setups.last?.secret,
                       OneTimeCodeSecret(key: Data("another-test-key-000".utf8), digits: 8, algorithm: .sha256))
        XCTAssertEqual(OneTimeCodeSetup.setups(in: "otpauth://totp/Example:ada@example.test"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example").setups, Array(found.setups.prefix(1)))

        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(), repository: InMemoryVaultRepository(), hmac: MacVault.hmac,
            isAllowedBuild: true, defaults: .vaultTests()))
        XCTAssertEqual(center.importOneTimeCodes(found.setups), 2)
        XCTAssertEqual(center.importOneTimeCodes(found.setups), 0)
        XCTAssertEqual(center.items.map(\.name), ["Example", "Second"])
        XCTAssertTrue(center.items.allSatisfy { $0.sites.isEmpty && $0.hasOneTimeCode && !$0.hasPassword })
    }

    /// A code imported with no site (design §14.3) is offered on the pages its name names, and not on a
    /// look-alike; an agent cannot fill it, and asking for it is no phishing sign; once the person picks it
    /// there it keeps the site, and on a site whose password is another item each fill takes the item that
    /// has what it asks for.
    func testACodeWithNoSiteIsOfferedWhereItsNameSaysAndKeepsTheSiteThePersonPicksItOn() async throws {
        XCTAssertTrue(VaultSite.isNamed("amazon.com", by: "Amazon Web Services (ada@123456789012)"))
        XCTAssertTrue(VaultSite.isNamed("linkedin.com", by: "Linked In"))
        XCTAssertFalse(VaultSite.isNamed("vercel-login.com", by: "Vercel"))
        XCTAssertFalse(VaultSite.isNamed("http://localhost:3000", by: "localhost"))

        let key = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))
        let vercel = VaultItem(name: "Vercel", sites: [], username: "ada@example.test")
        let aws = VaultItem(name: "Amazon Web Services", sites: [], username: "ada@123456789012")
        let gitHubCode = VaultItem(name: "GitHub", sites: [], username: "ada")
        let gitHub = VaultItem(name: "GitHub", sites: ["github.com"], username: "ada")
        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(), repository: InMemoryVaultRepository(), hmac: MacVault.hmac,
            isAllowedBuild: true, defaults: .vaultTests()))
        for item in [vercel, aws, gitHubCode] { try center.save(item, secret: VaultSecret(oneTimeCode: key)) }
        try center.save(gitHub, secret: VaultSecret(password: "correct horse"))
        var notices: [String] = []
        center.notify = { title, _, _ in notices.append(title) }
        let task = UUID()

        XCTAssertEqual(center.unlinkedCodeItems(for: "https://vercel.com").map(\.id), [vercel.id])
        XCTAssertEqual(center.unlinkedCodeItems(for: "https://signin.aws.amazon.com").map(\.id), [aws.id])
        XCTAssertEqual(center.unlinkedCodeItems(for: "https://vercel-login.com"), [])
        XCTAssertNil(center.valuesForPerson(vercel, origin: "https://vercel.com"))
        let asked: [(String?, String)] = [(nil, "https://vercel.com"), ("Vercel", "https://vercel.com"), (nil, "https://github.com")]
        for (name, origin) in asked {
            let refused = await center.authorize(VaultFillRequest(sessionID: task, itemName: name, kind: .oneTimeCode,
                                                                  origin: origin))
            guard case let .failure(refusal) = refused else { return XCTFail("an agent filled a code with no site") }
            XCTAssertTrue(refusal.message.contains("code bar"), refusal.message)
        }
        XCTAssertEqual(notices, [])

        center.link(vercel.id, to: "vercel.com")
        let linked = try XCTUnwrap(center.items.first { $0.id == vercel.id })
        XCTAssertEqual(linked.sites, ["vercel.com"])
        XCTAssertEqual(center.unlinkedCodeItems(for: "https://vercel.com"), [])
        XCTAssertEqual(center.valuesForPerson(linked, origin: "https://vercel.com")?.code?.count, 6)
        let agent = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .oneTimeCode,
                                                            origin: "https://vercel.com"))
        guard case .success = agent else { return XCTFail("the linked code did not fill on its site") }

        center.link(gitHubCode.id, to: "github.com")
        for (kind, item) in [(VaultFillKind.login, gitHub), (.oneTimeCode, gitHubCode)] {
            for name in [nil, "GitHub", "ada"] {
                let filled = await center.authorize(VaultFillRequest(sessionID: task, itemName: name, kind: kind,
                                                                     origin: "https://github.com"))
                guard case let .success(grant) = filled else { return XCTFail("\(kind) named \(name ?? "nothing") was refused") }
                XCTAssertEqual(grant.item.id, item.id)
            }
        }
    }

    func testAnItemAskedForOnAnotherSiteIsRefusedAndThePersonIsTold() async throws {
        let item = VaultItem(name: "GitHub", sites: ["github.com"], username: "ada", policy: .always)
        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct horse")]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        var notices: [String] = []
        center.notify = { title, _, _ in notices.append(title) }
        let task = UUID()

        let phishing = await center.authorize(VaultFillRequest(sessionID: task, itemName: "GitHub", kind: .login,
                                                               origin: "https://github-login.com"))
        guard case .failure = phishing else { return XCTFail("filled on another site") }
        XCTAssertEqual(notices.count, 1)

        let unnamed = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                              origin: "https://github-login.com"))
        guard case .failure = unnamed else { return XCTFail("filled on another site") }

        let own = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                          origin: "https://www.github.com"))
        guard case .success(let grant) = own else { return XCTFail("refused its own site") }
        XCTAssertEqual(grant.password, "correct horse")
        XCTAssertEqual(grant.confirmedBy, .always)

        center.isEnabled = false
        let off = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                          origin: "https://www.github.com"))
        guard case .failure = off else { return XCTFail("filled while off") }

        // Two accounts on one site under the site's name, as an import names them: the refusal tells them
        // apart by username, and the username names one.
        let other = VaultItem(name: "GitHub", sites: ["github.com"], username: "grace", policy: .always)
        let both = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct horse"),
                                               other.id: VaultSecret(password: "battery staple")]),
            repository: InMemoryVaultRepository(items: [item, other]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        for name in [nil, "GitHub"] {
            let refused = await both.authorize(VaultFillRequest(sessionID: task, itemName: name, kind: .login,
                                                                origin: "https://github.com"))
            guard case let .failure(refusal) = refused else { return XCTFail("filled one of two of that name") }
            XCTAssertTrue(refusal.message.contains("“GitHub” (ada)") && refusal.message.contains("“GitHub” (grace)"),
                          refusal.message)
        }
        let byUsername = await both.authorize(VaultFillRequest(sessionID: task, itemName: "grace", kind: .login,
                                                               origin: "https://github.com"))
        guard case let .success(chosen) = byUsername else { return XCTFail("the username did not name its item") }
        XCTAssertEqual(chosen.password, "battery staple")
    }

    /// Passwords the vault makes (design §15): Chrome's classes plus a symbol, without look-alikes, within a
    /// site's `passwordrules` and a field's `maxlength`; a draw past the last whole multiple of the range is
    /// drawn again (no modulo bias), and no password comes from a failed random source. A made password is
    /// kept beside, never over, a saved one of the same username, an agent makes one only for a new account,
    /// and a replaced password stays in the item.
    func testMadePasswordsMeetTheRulesAndNeverReplaceASavedPassword() async throws {
        let random = VaultPasswordGenerator.systemRandomBytes
        for _ in 0..<200 {
            let password = try XCTUnwrap(VaultPasswordGenerator.generate(rules: nil, random: random))
            XCTAssertEqual(password.count, 15)
            for set in [VaultPasswordGenerator.lower, VaultPasswordGenerator.upper, VaultPasswordGenerator.digits,
                        VaultPasswordGenerator.symbols] {
                XCTAssertTrue(password.contains(where: set.contains), password)
            }
            XCTAssertFalse(password.contains(where: VaultPasswordGenerator.lookAlikes.contains), password)
            XCTAssertFalse(password.contains("--") || password.contains("__"), password)
        }
        let rules = try XCTUnwrap(PasswordRules("minlength: 20; required: digit; required: [!@]; allowed: lower; max-consecutive: 2"))
        for _ in 0..<200 {
            let password = try XCTUnwrap(VaultPasswordGenerator.generate(rules: rules, random: random))
            XCTAssertEqual(password.count, 20)
            XCTAssertTrue(password.contains(where: \.isNumber) && password.contains(where: { "!@".contains($0) }), password)
            XCTAssertTrue(password.allSatisfy { $0.isLowercase || $0.isNumber || "!@".contains($0) }, password)
        }
        XCTAssertEqual(VaultPasswordGenerator.generate(rules: nil, fieldMaxLength: 8, random: random)?.count, 8)
        XCTAssertNil(PasswordRules("not a rule"))
        XCTAssertNil(VaultPasswordGenerator.generate(rules: nil, random: { _ in nil }))

        // 0xffffffff is past 3 × 1431655765, so the next draw (5) decides.
        let bytes: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0, 0, 0, 5] + Array(repeating: 0, count: 248)
        var draw = UnbiasedDraw(random: { count in Array(bytes.prefix(count)) })
        XCTAssertEqual(draw.index(below: 3), 2)

        let saved = VaultItem(name: "GitHub", sites: ["github.com"], username: "ada")
        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([saved.id: VaultSecret(password: "correct horse")]),
            repository: InMemoryVaultRepository(items: [saved]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        let beside = try center.presaveMadePassword("made-1", origin: "https://github.com", username: "ada")
        XCTAssertEqual(beside.username, "")
        XCTAssertEqual(center.secret(of: saved.id)?.password, "correct horse")
        let again = try center.presaveMadePassword("made-2", origin: "https://github.com", username: "ada", into: beside.id)
        XCTAssertEqual(again.id, beside.id)
        XCTAssertEqual(center.items.count, 2)
        XCTAssertEqual(center.secret(of: beside.id)?.previousPasswords?.map(\.password), ["made-1"])

        var updated = try XCTUnwrap(center.secret(of: saved.id))
        updated.password = "made-2"
        try center.save(saved, secret: updated)
        XCTAssertEqual(center.secret(of: saved.id)?.previousPasswords?.map(\.password), ["correct horse"])

        let request = { (name: String?) in
            VaultFillRequest(sessionID: UUID(), itemName: name, kind: .newPassword, origin: "https://github.com")
        }
        let sameUser = await center.authorizeNewPassword(request(nil), username: "ada")
        let sameName = await center.authorizeNewPassword(request("GitHub"), username: "")
        let newAccount = await center.authorizeNewPassword(request(nil), username: "grace")
        guard case .failure = sameUser, case .failure = sameName, case .success(.always) = newAccount else {
            return XCTFail("an agent's new password went over a saved one, or not into a new account")
        }
    }
}

extension UserDefaults {
    /// An empty defaults domain of the test's own, so a test that turns the vault off leaves the
    /// shared one alone.
    static func vaultTests() -> UserDefaults {
        UserDefaults(suiteName: testDefaultsSuite("yardlet.vault.tests"))!
    }
}
