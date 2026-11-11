#if DEBUG
import CommonCrypto
import CryptoKit
import CSQLite
import Foundation

/// A made-up Chromium data folder for the tests and QA of `BrowserLoginImport`: `Local State` naming its profiles and,
/// in each, a `Cookies` database in Chromium 154's schema (version 24) whose values are encrypted as Chromium encrypts
/// them on macOS, under a test password instead of a keychain item's, and, when it has visits, a `History` database in
/// Chromium's schema (version 70).
enum ChromiumProfileFixture {
    struct Cookie {
        /// As Chromium stores it: a leading dot for a domain cookie.
        var host: String
        var name: String
        var value: String
        var path = "/"
        var secure = true
        var httpOnly = true
        /// Chromium's: -1 unspecified, 0 none, 1 lax, 2 strict.
        var sameSite = 0
        /// Nil for a session cookie.
        var expires: Date? = Date().addingTimeInterval(86_400)
        /// The top-level site a partitioned (CHIPS) cookie is kept under.
        var partitionedUnder: String?
    }

    /// A visit as Chromium's `History` keeps it.
    struct Visit {
        var url: String
        var title = ""
        var date: Date
        /// `ui::PageTransition`: the core type in the low byte (0 link, 1 typed, 4 manual subframe, 5 generated, 8
        /// reload), with CHAIN_START 0x10000000 and CHAIN_END 0x20000000 for a page that was not redirected.
        var transition: Int64 = 0x3000_0000
        /// Chromium hides an address seen only in frames or redirects.
        var hidden = false
    }

    struct Profile {
        var folder: String
        var name: String
        var cookies: [Cookie]
        /// Chromium 96 and later keep the database in `Network`; Whale keeps it beside the profile.
        var inNetworkFolder = false
        var visits: [Visit] = []
    }

    /// Writes the browser's folder at `root` (Application Support's `<browser folder>`).
    static func make(at root: URL, profiles: [Profile], lastUsed: String, password: Data) throws {
        var cache: [String: Any] = [:]
        for profile in profiles { cache[profile.folder] = ["name": profile.name] }
        let state: [String: Any] = ["profile": ["info_cache": cache, "last_used": lastUsed,
                                                "profiles_order": profiles.map(\.folder)]]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state).write(to: root.appending(path: "Local State"))
        let key = BrowserLoginImport.cookieKey(password: password) ?? Data()
        for profile in profiles {
            let folder = root.appending(path: profile.inNetworkFolder ? "\(profile.folder)/Network" : profile.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeDatabase(folder.appending(path: "Cookies"), cookies: profile.cookies, key: key)
            if !profile.visits.isEmpty {
                try writeHistory(root.appending(path: profile.folder).appending(path: "History"), visits: profile.visits)
            }
        }
    }

    /// `urls` with each address's counts as Chromium keeps them, and `visits`.
    private static func writeHistory(_ url: URL, visits: [Visit]) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '70'), ('last_compatible_version', '16');
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
              visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
              last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL,
              from_visit INTEGER, external_referrer_url TEXT, transition INTEGER DEFAULT 0 NOT NULL, segment_id INTEGER,
              visit_duration INTEGER DEFAULT 0 NOT NULL, incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,
              opener_visit INTEGER, originator_cache_guid TEXT, originator_visit_id INTEGER, originator_from_visit INTEGER,
              originator_opener_visit INTEGER, is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,
              consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL, visited_link_id INTEGER DEFAULT 0 NOT NULL,
              app_id TEXT);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var ids: [String: Int64] = [:]
        for visit in visits where ids[visit.url] == nil {
            let all = visits.filter { $0.url == visit.url }
            var statement: OpaquePointer?
            let insert = "INSERT INTO urls(url, title, visit_count, typed_count, last_visit_time, hidden) VALUES(?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, visit.url, -1, transient)
            sqlite3_bind_text(statement, 2, visit.title, -1, transient)
            sqlite3_bind_int(statement, 3, Int32(all.filter { $0.transition & 0xFF != 8 }.count))
            sqlite3_bind_int(statement, 4, Int32(all.filter { $0.transition & 0xFF == 1 }.count))
            sqlite3_bind_int64(statement, 5, all.map { chromiumTime($0.date) }.max() ?? 0)
            sqlite3_bind_int(statement, 6, visit.hidden ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            ids[visit.url] = sqlite3_last_insert_rowid(handle)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO visits(url, visit_time, transition) VALUES(?, ?, ?)", -1, &statement, nil)
                == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        for visit in visits {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, ids[visit.url] ?? 0)
            sqlite3_bind_int64(statement, 2, chromiumTime(visit.date))
            sqlite3_bind_int64(statement, 3, visit.transition)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Chromium's `v10` value of a database at version 24: the host's SHA-256, then the value, under AES-128-CBC.
    static func encrypt(_ value: String, key: Data, hostKey: String) -> Data {
        let plain = Data(SHA256.hash(data: Data(hostKey.utf8))) + Data(value.utf8)
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let outputSize = output.count
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        _ = output.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, plain.count, out.baseAddress, outputSize, &written)
                }
            }
        }
        output.count = written
        return Data("v10".utf8) + output
    }

    private static func writeDatabase(_ url: URL, cookies: [Cookie], key: Data) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '24'), ('last_compatible_version', '24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
              has_cross_site_ancestor INTEGER NOT NULL);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        var statement: OpaquePointer?
        let insert = "INSERT INTO cookies VALUES(?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 2, 443, ?, 1, 0)"
        guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, cookie) in cookies.enumerated() {
            let now = chromiumTime(Date()) - Int64(cookies.count - index) * 1_000_000
            let encrypted = encrypt(cookie.value, key: key, hostKey: cookie.host)
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, now)
            sqlite3_bind_text(statement, 2, cookie.host, -1, transient)
            sqlite3_bind_text(statement, 3, cookie.partitionedUnder ?? "", -1, transient)
            sqlite3_bind_text(statement, 4, cookie.name, -1, transient)
            _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(encrypted.count), transient) }
            sqlite3_bind_text(statement, 6, cookie.path, -1, transient)
            sqlite3_bind_int64(statement, 7, cookie.expires.map(chromiumTime) ?? 0)
            sqlite3_bind_int(statement, 8, cookie.secure ? 1 : 0)
            sqlite3_bind_int(statement, 9, cookie.httpOnly ? 1 : 0)
            sqlite3_bind_int64(statement, 10, now)
            sqlite3_bind_int(statement, 11, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 12, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 13, Int32(cookie.sameSite))
            sqlite3_bind_int64(statement, 14, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Chromium's microseconds since 1601.
    static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }
}
#endif
