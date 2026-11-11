import Foundation
import XCTest
@testable import NativeHarnessClient

/// Another browser's sign-ins and visit history (docs/BROWSER_SESSION_ISOLATION.md 10), read from made-up Chromium
/// (under a test password) and Firefox data folders in a temporary directory; no keychain item and no real browser's
/// data.
final class BrowserLoginImportTests: XCTestCase {
    private static let password = Data("qa-safe-storage-not-real".utf8)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "BrowserLoginImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheKeyAndValuesDecryptAsChromiumOnMacMakesThem() throws {
        // Made with Python's PBKDF2 and openssl's AES-128-CBC, not with this code.
        let key = try XCTUnwrap(BrowserLoginImport.cookieKey(password: Self.password))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "207e7e2e1d7597c5a8fe934cded36332")
        let withHash = Data(hex: "763130b0951c1c8391f30454b49ee4e36a1df361666a42ad98be5524485c6ca6be5a7d8dae79e978cf2f214117e3840990eb0e")
        XCTAssertEqual(BrowserLoginImport.decrypt(withHash, key: key, hostKey: "accounts.example.com", version: 24), Data("signed-in".utf8))
        // From version 24 the value names its host: under another host it is refused.
        XCTAssertNil(BrowserLoginImport.decrypt(withHash, key: key, hostKey: "other.example.com", version: 24))
        let older = Data(hex: "763130fa424fb726e71f037486afc56fe4979a")
        XCTAssertEqual(BrowserLoginImport.decrypt(older, key: key, hostKey: "accounts.example.com", version: 23), Data("signed-in".utf8))
    }

    @MainActor
    func testProfilesSitesAndCookiesKeepTheirShape() throws {
        let support = root.appending(path: "Application Support")
        let expires = Date().addingTimeInterval(3600)
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        try ChromiumProfileFixture.make(at: support.appending(path: "Naver/Whale"), profiles: [
            .init(folder: "Default", name: "", cookies: []),
            .init(folder: "Profile 1", name: "Work", cookies: [
                .init(host: "accounts.example.com", name: "SID", value: "host-only", expires: expires),
                .init(host: "accounts.example.com", name: "__Host-SID", value: "host-prefixed", sameSite: 2, expires: expires),
                .init(host: ".example.com", name: "pref", value: "domain", secure: false, httpOnly: false, sameSite: -1, expires: nil),
                .init(host: "widget.example.com", name: "chips", value: "partitioned", partitionedUnder: "https://example.org"),
                .init(host: ".example.com", name: "old", value: "expired", expires: Date().addingTimeInterval(-60)),
                .init(host: "www.other.test", name: "other", value: "not chosen")
            ], visits: [
                // A user name and password in the address are dropped; typed is the core transition TYPED.
                .init(url: "https://user:secret@example.com/account", title: "Account", date: ago(24), transition: 0x3000_0001),
                .init(url: "https://example.com/account", date: ago(48)),
                .init(url: "https://example.com/account", date: ago(1), transition: 0x3000_0008),
                .init(url: "https://www.google.com/search?q=yardlet&oq=yardlet", date: ago(3), transition: 0x3000_0005),
                .init(url: "https://example.com/old", date: ago(24 * 100)),
                .init(url: "https://frame.example.com/", date: ago(2), transition: 0x3000_0004),
                // A redirect's source: the chain starts there and ends elsewhere.
                .init(url: "http://example.com/", date: ago(5), transition: 0x1000_0000),
                .init(url: "https://example.com/hidden", date: ago(6), hidden: true),
                .init(url: "chrome://settings/", date: ago(7))
            ]),
            .init(folder: "Profile 2", name: "Empty", cookies: [], inNetworkFolder: true)
        ], lastUsed: "Profile 1", password: Self.password)
        try ChromiumProfileFixture.make(at: support.appending(path: "Google/Chrome"), profiles: [
            .init(folder: "Default", name: "Person 1", cookies: [], inNetworkFolder: true)
        ], lastUsed: "Default", password: Self.password)
        // Opera keeps its first profile in its folder itself.
        try ChromiumProfileFixture.make(at: support.appending(path: "com.operasoftware.Opera"), profiles: [
            .init(folder: "", name: "", cookies: [])
        ], lastUsed: "", password: Self.password)

        let profiles = BrowserLoginImport.find(in: support).profiles
        XCTAssertEqual(profiles.map(\.title), ["Whale · Work", "Whale · Default", "Whale · Empty", "Chrome · Person 1", "Opera"])
        XCTAssertEqual(profiles[2].cookies.lastPathComponent, "Cookies")
        XCTAssertEqual(profiles[2].cookies.deletingLastPathComponent().lastPathComponent, "Network")
        let whale = profiles[0]

        XCTAssertEqual(Set(try BrowserLoginImport.sites(in: whale).map(\.domain)), ["example.com", "other.test"])
        let cookies = try BrowserLoginImport.cookies(in: whale, sites: ["example.com"], password: Self.password)
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["SID", "__Host-SID", "pref"])
        XCTAssertEqual(byName["SID"], BrowserImportedCookie(
            name: "SID", value: "host-only", domain: "accounts.example.com", path: "/", secure: true, httpOnly: true,
            sameSite: 1, priority: 0, expires: ChromiumProfileFixture.chromiumTime(expires)))
        XCTAssertEqual(byName["__Host-SID"]?.sameSite, 3)
        XCTAssertEqual(byName["pref"], BrowserImportedCookie(
            name: "pref", value: "domain", domain: ".example.com", path: "/", secure: false, httpOnly: false,
            sameSite: 0, priority: 0, expires: nil))

        XCTAssertThrowsError(try BrowserLoginImport.cookies(in: whale, sites: ["example.com"], password: Data("wrong".utf8))) {
            XCTAssertEqual($0 as? BrowserLoginImport.Failure, .undecryptable)
        }

        // The history: the pages Chromium shows in its own history, within 90 days, a Google results page as its
        // search, typed as Chromium recorded it.
        XCTAssertNil(profiles[1].history, "a profile with no History offers none")
        let history = try BrowserLoginImport.history(in: whale, since: nil, now: now)
        XCTAssertEqual(history.pages.map(\.url), ["https://example.com/account"])
        XCTAssertEqual(history.pages.first.map { [$0.visitCount, $0.typedCount] }, [2, 1])
        XCTAssertEqual(history.pages.first?.title, "Account")
        XCTAssertEqual(history.searches.map(\.terms), ["yardlet"])
        // Merged beside Yardlet's own visit; importing the profile again adds nothing it already brought.
        let addresses = BrowserAddressHistory(file: nil) { now }
        addresses.noteVisit("https://example.com/account", typed: false)
        addresses.merge(history, from: whale.id)
        let account = try XCTUnwrap(addresses.pages["https://example.com/account"])
        XCTAssertEqual([account.visitCount, account.typedCount, account.visits.count], [3, 1, 3])
        XCTAssertEqual(account.visits.map(\.date), account.visits.map(\.date).sorted(by: >))
        let again = try BrowserLoginImport.history(in: whale, since: addresses.importedUntil(whale.id), now: now)
        XCTAssertTrue(again.pages.isEmpty && again.searches.isEmpty, "\(again.pages.map(\.url))")
        addresses.merge(again, from: whale.id)
        XCTAssertEqual(addresses.pages["https://example.com/account"]?.visitCount, 3)
        XCTAssertEqual(addresses.searches["yardlet"]?.count, 1)
        // At most the newest 5000 pages come in.
        var importer = BrowserAddressHistory.Importer(now: now, since: nil)
        for index in 0...BrowserAddressHistory.maxPages {
            importer.add("https://example.com/\(index)", title: "", date: now.addingTimeInterval(-Double(index)), typed: false)
        }
        XCTAssertEqual(importer.result.pages.count, BrowserAddressHistory.maxPages)
        XCTAssertNil(importer.result.pages.first { $0.url.hasSuffix("/\(BrowserAddressHistory.maxPages)") })
    }

    func testFirefoxProfilesAndCookiesTakeChromiumsShape() throws {
        let support = root.appending(path: "Application Support")
        let expires = Date().addingTimeInterval(3600)
        try FirefoxProfileFixture.make(at: support.appending(path: "zen"), profiles: [
            .init(path: "Profiles/a.default", name: "default", cookies: []),
            .init(path: "Profiles/b.Work", name: "Work", cookies: [
                .init(host: "accounts.example.com", name: "SID", value: "host-only", sameSite: 2, expires: expires),
                .init(host: ".example.com", name: "pref", value: "unset", secure: false, httpOnly: false, sameSite: 256, expires: expires),
                .init(host: ".example.com", name: "cross", value: "none", sameSite: 0),
                .init(host: ".example.com", name: "plain", value: "none, not secure", secure: false, sameSite: 0),
                .init(host: "accounts.example.com", name: "SID", value: "container", originAttributes: "^userContextId=1"),
                .init(host: "widget.example.com", name: "chips", value: "partitioned",
                      originAttributes: "^partitionKey=%28https%2Cexample.org%29"),
                .init(host: ".example.com", name: "old", value: "expired", expires: Date().addingTimeInterval(-60)),
                .init(host: "www.other.test", name: "other", value: "not chosen")
            ], visits: [
                .init(url: "https://example.com/home", title: "Home", date: Date().addingTimeInterval(-3600), type: 2),
                .init(url: "https://example.com/home", date: Date().addingTimeInterval(-7200)),
                .init(url: "https://example.com/home", date: Date().addingTimeInterval(-60), type: 9),
                .init(url: "https://example.com/frame", date: Date().addingTimeInterval(-60), type: 8),
                .init(url: "https://example.com/go", date: Date().addingTimeInterval(-60), hidden: true),
                .init(url: "https://www.google.com/search?q=zen", date: Date().addingTimeInterval(-60))
            ])
        ], installed: "Profiles/b.Work", marked: "Profiles/a.default")
        // A browser whose list of profiles exists but cannot be read, as macOS 27 keeps Chrome's.
        let chrome = support.appending(path: "Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: chrome.appending(path: "Local State"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chrome.appending(path: "Local State").path)

        let found = BrowserLoginImport.find(in: support)
        XCTAssertEqual(found.profiles.map(\.title), ["Zen · Work", "Zen · default"])
        XCTAssertEqual(found.unreadable.map(\.name), ["Chrome"])
        let work = found.profiles[0]
        XCTAssertEqual(Set(try BrowserLoginImport.sites(in: work).map(\.domain)), ["example.com", "other.test"])
        let cookies = try BrowserLoginImport.cookies(in: work, sites: ["example.com"], password: Data())
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["SID", "pref", "cross", "plain"])
        // Firefox keeps milliseconds since 1970; Chromium, microseconds since 1601.
        XCTAssertEqual(byName["SID"], BrowserImportedCookie(
            name: "SID", value: "host-only", domain: "accounts.example.com", path: "/", secure: true, httpOnly: true,
            sameSite: 3, priority: 0, expires: Int64(expires.timeIntervalSince1970 * 1000) * 1000 + 11_644_473_600_000_000))
        XCTAssertEqual(byName["pref"]?.domain, ".example.com")
        XCTAssertEqual(byName.mapValues(\.sameSite), ["SID": 3, "pref": 0, "cross": 1, "plain": 0])

        // Firefox's history: no reload, framed link or hidden page; typed as `TRANSITION_TYPED`.
        let history = try BrowserLoginImport.history(in: work, since: nil)
        XCTAssertEqual(history.pages.map(\.url), ["https://example.com/home"])
        XCTAssertEqual(history.pages.first.map { [$0.visitCount, $0.typedCount] }, [2, 1])
        XCTAssertEqual(history.searches.map(\.terms), ["zen"])
    }

    func testASiteIsItsRegistrableDomainOrTheHostItself() {
        XCTAssertEqual(BrowserLoginImport.site(of: ".accounts.google.com"), "google.com")
        XCTAssertEqual(BrowserLoginImport.site(of: "alice.github.io"), "alice.github.io")
        XCTAssertEqual(BrowserLoginImport.site(of: "localhost"), "localhost")
        XCTAssertEqual(BrowserLoginImport.site(of: "127.0.0.1"), "127.0.0.1")
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
