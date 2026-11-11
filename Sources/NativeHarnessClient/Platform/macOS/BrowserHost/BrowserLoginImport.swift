import CommonCrypto
import CryptoKit
import CSQLite
import Foundation
import Security

/// Another browser's sign-ins for the sites a person chooses, brought into Yardlet's browser
/// (docs/BROWSER_SESSION_ISOLATION.md 10). A site that signs in only with a passkey kept by another browser (iCloud
/// Keychain, Whale, Chrome) cannot be signed in to here; its cookies from that browser can be brought over, and the
/// person may then add a Yardlet passkey on the site. Chromium browsers list their profiles in `Local State` and keep a
/// profile's cookies in a `Cookies` database, values encrypted under a key made from a password in the login keychain
/// (`<browser> Safe Storage`); Firefox browsers list theirs in `profiles.ini` and keep cookies in plain text in
/// `cookies.sqlite`. macOS 27 lets only Chrome, Edge, Brave and Firefox themselves, or an app with Full Disk Access,
/// read their folders; Safari keeps its cookies where only such an app reads them, so it is not offered. Listing a
/// profile's sites reads hosts only; the keychain is read when the person imports, and the key lives in memory for that
/// import alone. Values go to the browser host and nowhere else. The same profiles' visit history (Chromium's `History`,
/// Firefox's `places.sqlite`) can come along into the address field's history (`history(in:since:now:)`), with no key.
enum BrowserLoginImport {
    /// A browser to import from: its folder under Application Support, how it keeps cookies, and its app.
    struct Browser: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// Encrypts cookie values under the password of the login keychain item with this service.
            case chromium(keychainService: String)
            case firefox
        }

        var name: String
        var folder: String
        var kind: Kind
        /// The app's bundle identifier, for its icon.
        var bundleID: String

        var keychainService: String? {
            guard case .chromium(let service) = kind else { return nil }
            return service
        }
    }

    /// Whale first, then the other Chromium browsers and the Firefox ones, each as its own bundle names its folder
    /// (`CrProductDirName`, `application.ini`'s `Profile` or `Name`) and its keychain item; the evidence for each is in
    /// docs/BROWSER_SESSION_ISOLATION.md 10. Opera GX shares Opera's item name.
    static let knownBrowsers: [Browser] = [
        ("Whale", "Naver/Whale", "Whale Safe Storage", "com.naver.Whale"),
        ("Chrome", "Google/Chrome", "Chrome Safe Storage", "com.google.Chrome"),
        ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "com.microsoft.edgemac"),
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage", "com.brave.Browser"),
        ("Arc", "Arc/User Data", "Arc Safe Storage", "company.thebrowser.Browser"),
        ("Comet", "Comet", "Comet Safe Storage", "ai.perplexity.comet"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage", "com.vivaldi.Vivaldi"),
        ("Opera", "com.operasoftware.Opera", "Opera Safe Storage", "com.operasoftware.Opera"),
        ("Opera GX", "com.operasoftware.OperaGX", "Opera Safe Storage", "com.operasoftware.OperaGX"),
        ("Yandex", "Yandex/YandexBrowser", "Yandex Safe Storage", "ru.yandex.desktop.yandex-browser"),
        ("Helium", "net.imput.helium", "Helium Storage Key", "net.imput.helium"),
        ("Chromium", "Chromium", "Chromium Safe Storage", "org.chromium.Chromium")
    ].map { Browser(name: $0.0, folder: $0.1, kind: .chromium(keychainService: $0.2), bundleID: $0.3) } + [
        ("Firefox", "Firefox", "org.mozilla.firefox"),
        ("Zen", "zen", "app.zen-browser.zen"),
        ("Floorp", "Floorp", "app.floorp.Floorp"),
        ("LibreWolf", "librewolf", "net.librewolf.librewolf"),
        ("Waterfox", "Waterfox", "net.waterfox.waterfox")
    ].map { Browser(name: $0.0, folder: $0.1, kind: .firefox, bundleID: $0.2) }

    /// A browser profile that keeps cookies.
    struct Profile: Hashable, Identifiable, Sendable {
        var browser: Browser
        /// The profile's folder (`Default`, `Profile 1`; `Profiles/x.default-release` for Firefox; empty when the
        /// browser keeps its first profile in its folder itself, as Opera does).
        var folder: String
        /// The name the browser shows for it.
        var name: String
        var cookies: URL
        /// The profile's visit history (`History`, `places.sqlite`), when it has one.
        var history: URL?
        var id: String { browser.name + "/" + folder }
        var title: String { folder.isEmpty ? browser.name : "\(browser.name) · \(name)" }
    }

    /// The profiles on this Mac that keep cookies, and the browsers with a folder here that Yardlet may not read.
    struct Found: Sendable {
        var profiles: [Profile]
        var unreadable: [Browser]
    }

    /// A site with cookies in a profile.
    struct Site: Hashable, Identifiable, Sendable {
        /// The registrable domain (`naver.com`), or the host itself when it has none (`localhost`, an IP address).
        var domain: String
        /// When the browser last sent one of its cookies, in Chromium's microseconds since 1601.
        var lastUsed: Int64
        var id: String { domain }
    }

    enum Failure: LocalizedError, Equatable {
        /// The database could not be read, as the browser was writing it each time it was copied.
        case unreadable
        /// The same, for the visit history.
        case historyUnreadable
        case keychainMissing(browser: String)
        case keychainDenied(browser: String)
        /// No cookie decrypted: the key is not this profile's.
        case undecryptable
        case hostDidNotAnswer

        var errorDescription: String? {
            switch self {
            case .unreadable:
                L10n.string("The browser's cookies could not be read. Try again in a moment.")
            case .historyUnreadable:
                L10n.string("The browser's visit history could not be read. Try again in a moment.")
            case .keychainMissing(let browser):
                L10n.format("%@'s cookie key is not in the keychain.", browser)
            case .keychainDenied(let browser):
                L10n.format("Nothing was imported: access to %@'s keychain item was not allowed.", browser)
            case .undecryptable:
                L10n.string("The browser's cookies could not be decrypted with its key.")
            case .hostDidNotAnswer:
                L10n.string("Yardlet's browser did not take the sign-ins. Try again.")
            }
        }
    }

    /// The person's Application Support. QA runs give Yardlet a home of its own, which `NSHomeDirectory` follows.
    static var applicationSupport: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    // MARK: Browsers and sites

    /// The browsers on this Mac with a profile that keeps cookies, in `knownBrowsers` order, each one's last used
    /// profile first and then the browser's own order. A browser whose list of profiles exists but cannot be read is
    /// `unreadable`: macOS 27 keeps Chrome's, Edge's, Brave's and Firefox's folders to themselves, without asking.
    static func find(in applicationSupport: URL = BrowserLoginImport.applicationSupport,
                     browsers: [Browser] = knownBrowsers) -> Found {
        var found = Found(profiles: [], unreadable: [])
        for browser in browsers {
            let root = applicationSupport.appending(path: browser.folder, directoryHint: .isDirectory)
            let list = root.appending(path: browser.kind == .firefox ? "profiles.ini" : "Local State")
            guard let data = try? Data(contentsOf: list) else {
                if FileManager.default.fileExists(atPath: list.path(percentEncoded: false)) { found.unreadable.append(browser) }
                continue
            }
            found.profiles += browser.kind == .firefox ? firefoxProfiles(browser, root: root, list: data)
                : chromiumProfiles(browser, root: root, list: data)
        }
        return found
    }

    private static func chromiumProfiles(_ browser: Browser, root: URL, list: Data) -> [Profile] {
        guard let state = try? JSONSerialization.jsonObject(with: list) as? [String: Any],
              let profile = state["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let order = (profile["profiles_order"] as? [String] ?? []).filter { cache[$0] != nil }
        var folders = order + cache.keys.filter { !order.contains($0) }.sorted()
        if let last = profile["last_used"] as? String, let index = folders.firstIndex(of: last) {
            folders.insert(folders.remove(at: index), at: 0)
        }
        // Opera keeps its first profile in the browser's folder itself.
        if !folders.contains("") { folders.append("") }
        return folders.compactMap { folder in
            // Chromium moved the database into `Network` (Chrome 96); Whale and Comet keep it beside the profile.
            let profileRoot = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
            let candidates = ["Network/Cookies", "Cookies"].map { profileRoot.appending(path: $0) }
            guard let cookies = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
            else { return nil }
            let info = cache[folder] as? [String: Any]
            let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
            return Profile(browser: browser, folder: folder, name: name, cookies: cookies,
                           history: existing(profileRoot.appending(path: "History")))
        }
    }

    /// `profiles.ini`'s profiles: the one each installation uses first, then the one marked default, then the file's
    /// order. A profile's `Path` is under the browser's folder when `IsRelative=1`.
    private static func firefoxProfiles(_ browser: Browser, root: URL, list: Data) -> [Profile] {
        var sections: [(name: String, values: [String: String])] = []
        for line in String(decoding: list, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1].values[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        let profiles = sections.filter { $0.name.hasPrefix("Profile") && $0.values["Path"] != nil }.map { $0.values }
        let paths = profiles.compactMap { $0["Path"] }
        let first = sections.filter { $0.name.hasPrefix("Install") }.compactMap { $0.values["Default"] }
            + profiles.filter { $0["Default"] == "1" }.compactMap { $0["Path"] }
        var order: [String] = []
        for path in first.filter({ paths.contains($0) }) + paths where !order.contains(path) { order.append(path) }
        return order.compactMap { path in
            guard let values = profiles.first(where: { $0["Path"] == path }) else { return nil }
            let folder = values["IsRelative"] == "1" ? root.appending(path: path, directoryHint: .isDirectory)
                : URL(filePath: path, directoryHint: .isDirectory)
            let cookies = folder.appending(path: "cookies.sqlite")
            guard FileManager.default.fileExists(atPath: cookies.path(percentEncoded: false)) else { return nil }
            let name = values["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            return Profile(browser: browser, folder: path, name: name, cookies: cookies,
                           history: existing(folder.appending(path: "places.sqlite")))
        }
    }

    private static func existing(_ file: URL) -> URL? {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
    }

    /// The sites the profile has cookies for (unpartitioned and not expired), most recently used first. Reads hosts
    /// and times only.
    static func sites(in profile: Profile, suffixes: PublicSuffixList = .bundled, now: Date = Date()) throws -> [Site] {
        let hosts = try reading(profile.cookies) { handle -> [String: Int64]? in
            let sql: String
            if profile.browser.kind == .firefox {
                guard let table = MozTable(handle) else { return nil }
                // Firefox's times are microseconds since 1970.
                sql = """
                    SELECT host, MAX(lastAccessed) + \(chromiumEpochOffset) FROM moz_cookies
                    WHERE \(table.unpartitioned) AND \(table.unexpired(now)) GROUP BY host
                    """
            } else {
                guard let table = Table(handle) else { return nil }
                sql = """
                    SELECT host_key, MAX(\(table.lastAccess)) FROM cookies WHERE \(table.unpartitioned) AND NOT (\(table.expired(now)))
                    GROUP BY host_key
                    """
            }
            var hosts: [String: Int64] = [:]
            guard query(handle, sql, each: { hosts[text($0, 0)] = sqlite3_column_int64($0, 1) }) != nil else { return nil }
            return hosts
        }
        var sites: [String: Int64] = [:]
        for (host, used) in hosts where !host.isEmpty {
            sites[site(of: host, suffixes: suffixes)] = max(sites[site(of: host, suffixes: suffixes)] ?? 0, used)
        }
        return sites.map { Site(domain: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.domain < $1.domain }
    }

    /// The site a cookie's host belongs to: its registrable domain, or the host when it has none.
    static func site(of hostKey: String, suffixes: PublicSuffixList = .bundled) -> String {
        let host = (hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : hostKey).lowercased()
        let isAddress = host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard !isAddress else { return host }
        return suffixes.registrableDomain(of: host) ?? host
    }

    // MARK: Cookies

    /// The profile's cookies of `sites` and their subdomains, decrypted with the browser's password (a Firefox
    /// browser's need none): unpartitioned cookies that have not expired, each as Chromium stores it. A cookie that
    /// does not decrypt is left out; when none does, the password is not this profile's.
    static func cookies(in profile: Profile, sites: [String], password: Data, now: Date = Date()) throws -> [BrowserImportedCookie] {
        if profile.browser.kind == .firefox { return try firefoxCookies(in: profile, sites: sites, now: now) }
        guard var key = cookieKey(password: password) else { throw Failure.undecryptable }
        defer { key.resetBytes(in: 0..<key.count) }
        var failed = 0
        let cookies = try reading(profile.cookies) { handle -> [BrowserImportedCookie]? in
            guard let table = Table(handle) else { return nil }
            var version = 0
            _ = query(handle, "SELECT value FROM meta WHERE key = 'version'") { version = Int(text($0, 0)) ?? 0 }
            var found: [BrowserImportedCookie] = []
            let sql = """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, \(table.sameSite),
                  \(table.priority), \(table.hasExpires)
                FROM cookies WHERE \(table.unpartitioned) AND NOT (\(table.expired(now)))
                """
            failed = 0
            guard query(handle, sql, each: { statement in
                let host = text(statement, 0)
                guard sites.contains(where: { covers($0.lowercased(), host) }) else { return }
                let encrypted = blob(statement, 3)
                let plain = encrypted.isEmpty ? Optional(Data(text(statement, 2).utf8))
                    : decrypt(encrypted, key: key, hostKey: host, version: version)
                guard let plain, let value = String(data: plain, encoding: .utf8) else {
                    failed += 1
                    return
                }
                let hasExpires = sqlite3_column_int64(statement, 10) != 0
                found.append(BrowserImportedCookie(
                    name: text(statement, 1), value: value, domain: host, path: text(statement, 4),
                    secure: sqlite3_column_int64(statement, 6) != 0, httpOnly: sqlite3_column_int64(statement, 7) != 0,
                    // Chromium stores SameSite from -1 (unspecified) and priority from 0 (low); CEF counts from 0 and -1.
                    sameSite: min(max(Int(sqlite3_column_int64(statement, 8)) + 1, 0), 3),
                    priority: min(max(Int(sqlite3_column_int64(statement, 9)) - 1, -1), 1),
                    expires: hasExpires ? sqlite3_column_int64(statement, 5) : nil))
            }) != nil else { return nil }
            return found
        }
        if cookies.isEmpty, failed > 0 { throw Failure.undecryptable }
        return cookies
    }

    /// Firefox's cookies of `sites` in Chromium's shape. Firefox keeps no session cookie on disk, so each has an
    /// expiry; it has no priority, so each is medium.
    private static func firefoxCookies(in profile: Profile, sites: [String], now: Date) throws -> [BrowserImportedCookie] {
        try reading(profile.cookies) { handle -> [BrowserImportedCookie]? in
            guard let table = MozTable(handle) else { return nil }
            var found: [BrowserImportedCookie] = []
            let sql = """
                SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(table.sameSite), \(table.rawSameSite)
                FROM moz_cookies WHERE \(table.unpartitioned) AND \(table.unexpired(now))
                """
            guard query(handle, sql, each: { statement in
                let host = text(statement, 0)
                guard sites.contains(where: { covers($0.lowercased(), host) }) else { return }
                let secure = sqlite3_column_int64(statement, 5) != 0
                found.append(BrowserImportedCookie(
                    name: text(statement, 1), value: text(statement, 2), domain: host, path: text(statement, 3),
                    secure: secure, httpOnly: sqlite3_column_int64(statement, 6) != 0,
                    sameSite: MozTable.sameSite(Int(sqlite3_column_int64(statement, 7)), raw: Int(sqlite3_column_int64(statement, 8)),
                                                secure: secure),
                    priority: 0, expires: table.chromiumExpiry(sqlite3_column_int64(statement, 4))))
            }) != nil else { return nil }
            return found
        }
    }

    /// Whether a cookie's host key belongs to `site`: the site itself or one of its subdomains.
    static func covers(_ site: String, _ hostKey: String) -> Bool {
        let host = (hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : hostKey).lowercased()
        return host == site || host.hasSuffix("." + site)
    }

    /// The browser's cookie password from the login keychain, found by its service alone (each browser keeps one
    /// item under it). The item is the browser's, so macOS asks the person first ("Yardlet wants to use your
    /// confidential information stored in “Whale Safe Storage”").
    static func keychainPassword(for browser: Browser) throws -> Data {
        guard let service = browser.keychainService else { throw Failure.keychainMissing(browser: browser.name) }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw Failure.keychainMissing(browser: browser.name) }
            return data
        case errSecItemNotFound:
            throw Failure.keychainMissing(browser: browser.name)
        default:
            throw Failure.keychainDenied(browser: browser.name)
        }
    }

    /// Chromium's cookie key on macOS: PBKDF2-HMAC-SHA1 of the keychain password, salt "saltysalt", 1003 rounds,
    /// 16 bytes (`os_crypt_mac.mm`).
    static func cookieKey(password: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                                     password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        return status == Int32(kCCSuccess) ? key : nil
    }

    /// A `v10` value: AES-128-CBC with sixteen spaces for its IV and PKCS#7 padding. From database version 24 the
    /// plaintext starts with the SHA-256 of the cookie's host key (`kEncryptedDomainHashVersion`), which must match.
    static func decrypt(_ encrypted: Data, key: Data, hostKey: String, version: Int) -> Data? {
        let prefix = Data("v10".utf8)
        guard encrypted.count > prefix.count, encrypted.prefix(prefix.count) == prefix else { return nil }
        let body = encrypted.dropFirst(prefix.count)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: body.count + kCCBlockSizeAES128)
        var written = 0
        let outputSize = output.count
        let status = output.withUnsafeMutableBytes { out in
            body.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, body.count, out.baseAddress, outputSize, &written)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        output.count = written
        guard version >= 24 else { return output }
        let hash = Data(SHA256.hash(data: Data(hostKey.utf8)))
        guard output.count >= hash.count, output.prefix(hash.count) == hash else { return nil }
        return Data(output.dropFirst(hash.count))
    }

    // MARK: Visit history

    /// The profile's visits after `since` (an earlier import's newest) and within the address history's 90 days, in
    /// the address history's shape (`BrowserAddressHistory.Importer`). Only the visits each browser shows in its own
    /// history count: Chromium's visible visits (`VisitDatabase::GetVisibleVisitsInRange`: the end of a redirect
    /// chain, no frame or keyword visit) without reloads, typed when their core transition is `TYPED`; Firefox's
    /// visits of pages not hidden, without embeds, frames, downloads and reloads (the ones its `visit_count` leaves
    /// out), typed when `TRANSITION_TYPED`. Read newest first from a copy, as cookies are; no key is needed.
    static func history(in profile: Profile, since: Date?, now: Date = Date()) throws -> BrowserAddressHistory.Imported {
        guard let database = profile.history else { return BrowserAddressHistory.Imported() }
        let start = BrowserAddressHistory.Importer(now: now, since: since)
        // Rounded up, a visit an earlier import brought is never read again.
        let after = Int64((start.after.timeIntervalSince1970 * 1_000_000).rounded(.up))
        do {
            return try reading(database) { handle -> BrowserAddressHistory.Imported? in
                var importer = start
                let sql: String
                let epoch: Int64
                if profile.browser.kind == .firefox {
                    guard columns(handle, "moz_places").isSuperset(of: ["id", "url", "title", "hidden"]),
                          columns(handle, "moz_historyvisits").isSuperset(of: ["place_id", "visit_date", "visit_type"])
                    else { return nil }
                    // nsINavHistoryService: 2 typed, 4 embed, 7 download, 8 framed link, 9 reload.
                    sql = """
                        SELECT p.url, p.title, v.visit_date, v.visit_type = 2 FROM moz_historyvisits v
                        JOIN moz_places p ON p.id = v.place_id
                        WHERE p.hidden = 0 AND v.visit_date > \(after) AND v.visit_type NOT IN (0, 4, 7, 8, 9)
                        ORDER BY v.visit_date DESC
                        """
                    epoch = 0
                } else {
                    guard columns(handle, "urls").isSuperset(of: ["id", "url", "title", "hidden"]),
                          columns(handle, "visits").isSuperset(of: ["url", "visit_time", "transition"]) else { return nil }
                    // ui::PageTransition: the core type in the low byte (1 typed, 3 and 4 frames, 8 reload, 10
                    // keyword generated), CHAIN_END 0x20000000.
                    sql = """
                        SELECT u.url, u.title, v.visit_time, (v.transition & 255) = 1 FROM visits v
                        JOIN urls u ON u.id = v.url
                        WHERE u.hidden = 0 AND v.visit_time > \(after + chromiumEpochOffset)
                          AND (v.transition & 536870912) != 0 AND (v.transition & 255) NOT IN (3, 4, 8, 10)
                        ORDER BY v.visit_time DESC
                        """
                    epoch = chromiumEpochOffset
                }
                guard query(handle, sql, each: { statement in
                    let micros = sqlite3_column_int64(statement, 2) - epoch
                    importer.add(text(statement, 0), title: text(statement, 1),
                                 date: Date(timeIntervalSince1970: Double(micros) / 1_000_000),
                                 typed: sqlite3_column_int64(statement, 3) != 0)
                }) != nil else { return nil }
                return importer.result
            }
        } catch Failure.unreadable {
            throw Failure.historyUnreadable
        }
    }

    private static func columns(_ handle: OpaquePointer, _ table: String) -> Set<String> {
        var columns = Set<String>()
        _ = query(handle, "PRAGMA table_info(\(table))") { columns.insert(text($0, 1)) }
        return columns
    }

    // MARK: The database

    /// The `cookies` table's columns that vary between Chromium versions, as SQL.
    private struct Table {
        let sameSite: String
        let priority: String
        let hasExpires: String
        let lastAccess: String
        /// A cookie partitioned under a top-level site (CHIPS) cannot be set through CEF without becoming every
        /// site's cookie, so it stays behind.
        let unpartitioned: String

        init?(_ handle: OpaquePointer) {
            var columns = Set<String>()
            guard query(handle, "PRAGMA table_info(cookies)", each: { columns.insert(text($0, 1)) }) != nil else { return nil }
            let needed: Set = ["host_key", "name", "value", "encrypted_value", "path", "expires_utc", "is_secure", "is_httponly"]
            guard needed.isSubset(of: columns) else { return nil }
            sameSite = columns.contains("samesite") ? "samesite" : "-1"
            priority = columns.contains("priority") ? "priority" : "1"
            hasExpires = columns.contains("has_expires") ? "has_expires"
                : columns.contains("is_persistent") ? "is_persistent" : "expires_utc != 0"
            lastAccess = columns.contains("last_access_utc") ? "last_access_utc" : "0"
            unpartitioned = columns.contains("top_frame_site_key") ? "top_frame_site_key = ''" : "1"
        }

        /// Chromium's times are microseconds since 1601.
        func expired(_ now: Date) -> String {
            let chromiumNow = Int64(now.timeIntervalSince1970 * 1_000_000) + chromiumEpochOffset
            return "\(hasExpires) != 0 AND expires_utc <= \(chromiumNow)"
        }
    }

    /// Microseconds from 1601, where Chromium's times start, to 1970.
    private static let chromiumEpochOffset: Int64 = 11_644_473_600 * 1_000_000

    /// Firefox's `moz_cookies` (`CookiePersistentStorage.cpp`), whose columns and units vary with its schema version.
    private struct MozTable {
        /// Expiry in milliseconds from schema 16, seconds before.
        let expiryPerSecond: Int64
        let sameSite: String
        /// Before schema 15 a cookie sent without SameSite was stored as Lax with a raw None.
        let rawSameSite: String
        /// Only the default identity's first-party cookies: `originAttributes` names a partition (`partitionKey`), a
        /// container (`userContextId`) or a private window otherwise.
        let unpartitioned: String

        init?(_ handle: OpaquePointer) {
            var columns = Set<String>()
            guard query(handle, "PRAGMA table_info(moz_cookies)", each: { columns.insert(text($0, 1)) }) != nil else { return nil }
            let needed: Set = ["host", "name", "value", "path", "expiry", "lastAccessed", "isSecure", "isHttpOnly"]
            guard needed.isSubset(of: columns) else { return nil }
            var version: Int64 = 0
            _ = query(handle, "PRAGMA user_version") { version = sqlite3_column_int64($0, 0) }
            expiryPerSecond = version >= 16 ? 1000 : 1
            sameSite = columns.contains("sameSite") ? "sameSite" : "256"
            rawSameSite = columns.contains("rawSameSite") ? "rawSameSite" : "-1"
            unpartitioned = columns.contains("originAttributes") ? "originAttributes = ''" : "1"
        }

        func unexpired(_ now: Date) -> String {
            "expiry > \(Int64(now.timeIntervalSince1970 * Double(expiryPerSecond)))"
        }

        /// The expiry in Chromium's microseconds since 1601, held at the year 9999.
        func chromiumExpiry(_ expiry: Int64) -> Int64 {
            min(expiry, 253_402_300_799 * expiryPerSecond) * (1_000_000 / expiryPerSecond) + chromiumEpochOffset
        }

        /// Firefox's SameSite (0 none, 1 lax, 2 strict, 256 unset) as CEF counts it (0 unspecified, 1 none, 2 lax,
        /// 3 strict). Chromium refuses None on a cookie that is not Secure, so such a cookie stays unspecified.
        static func sameSite(_ value: Int, raw: Int, secure: Bool) -> Int {
            switch value {
            case 0: secure ? 1 : 0
            case 1: raw == 0 ? 0 : 2
            case 2: 3
            default: 0
            }
        }
    }

    /// Reads a copy of the database, made with its journal in a private temporary folder and removed after it is
    /// read: the browser may be writing the original, which stays untouched. The copy opens read-only; a copy taken
    /// in the middle of a write cannot be read so, and is taken again.
    private static func reading<T>(_ database: URL, _ body: (OpaquePointer) throws -> T?) throws -> T {
        let manager = FileManager.default
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            let folder = manager.temporaryDirectory.appending(path: "Yardlet browser import \(UUID().uuidString)", directoryHint: .isDirectory)
            guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])) != nil else { continue }
            defer { try? manager.removeItem(at: folder) }
            let copy = folder.appending(path: database.lastPathComponent)
            do {
                for suffix in ["", "-journal", "-wal"] {
                    let file = URL(filePath: database.path(percentEncoded: false) + suffix)
                    guard suffix.isEmpty || manager.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
                    try manager.copyItem(at: file, to: URL(filePath: copy.path(percentEncoded: false) + suffix))
                }
            } catch {
                continue
            }
            var handle: OpaquePointer?
            defer { sqlite3_close(handle) }
            guard sqlite3_open_v2(copy.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let opened = handle else { continue }
            if let result = try body(opened) { return result }
        }
        throw Failure.unreadable
    }

    /// Runs `sql`, calling `each` for every row: the number of rows, nil on an error.
    @discardableResult
    private static func query(_ handle: OpaquePointer, _ sql: String, each: (OpaquePointer) -> Void) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else { return nil }
        defer { sqlite3_finalize(prepared) }
        var rows = 0
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW:
                each(prepared)
                rows += 1
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
