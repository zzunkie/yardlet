#if DEBUG
import CSQLite
import Foundation

/// A made-up Firefox data folder for the tests and QA of `BrowserLoginImport`: `profiles.ini` naming its profiles, the
/// installation's own first, and in each a `cookies.sqlite` in Firefox 158's schema (version 17: expiry in
/// milliseconds, SameSite 256 when the site sent none) in WAL mode, values in plain text as Firefox keeps them, and,
/// when it has visits, a `places.sqlite` with `moz_places` and `moz_historyvisits`.
enum FirefoxProfileFixture {
    struct Cookie {
        /// As Firefox stores it: a leading dot for a domain cookie.
        var host: String
        var name: String
        var value: String
        var path = "/"
        var secure = true
        var httpOnly = true
        /// Firefox's: 0 none, 1 lax, 2 strict, 256 unset.
        var sameSite = 0
        var expires = Date().addingTimeInterval(86_400)
        /// `^partitionKey=…` for a partitioned cookie, `^userContextId=1` for a container's.
        var originAttributes = ""
    }

    /// A visit as Firefox's `places.sqlite` keeps it.
    struct Visit {
        var url: String
        var title = ""
        var date: Date
        /// nsINavHistoryService: 1 link, 2 typed, 5 and 6 redirects, 7 download, 8 framed link, 9 reload.
        var type = 1
        /// Firefox hides a redirect's source and frames' pages.
        var hidden = false
    }

    struct Profile {
        /// Under the browser's folder, as `profiles.ini` names it (`Profiles/x.default-release`).
        var path: String
        var name: String
        var cookies: [Cookie]
        var visits: [Visit] = []
    }

    /// Writes the browser's folder at `root` (Application Support's `<browser folder>`); `installed` is the profile the
    /// installation uses, `marked` the one `profiles.ini` marks default.
    static func make(at root: URL, profiles: [Profile], installed: String, marked: String? = nil) throws {
        var ini = "[General]\nStartWithLastProfile=1\nVersion=2\n\n"
        for (index, profile) in profiles.enumerated() {
            ini += "[Profile\(index)]\nName=\(profile.name)\nIsRelative=1\nPath=\(profile.path)\n"
            if profile.path == marked { ini += "Default=1\n" }
            ini += "\n"
        }
        ini += "[Install2656FF1E876E9973]\nDefault=\(installed)\nLocked=1\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(ini.utf8).write(to: root.appending(path: "profiles.ini"))
        for profile in profiles {
            let folder = root.appending(path: profile.path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeDatabase(folder.appending(path: "cookies.sqlite"), cookies: profile.cookies)
            if !profile.visits.isEmpty { try writePlaces(folder.appending(path: "places.sqlite"), visits: profile.visits) }
        }
    }

    /// `moz_places` with each address's counts as Firefox keeps them, and `moz_historyvisits`; times in microseconds
    /// since 1970.
    private static func writePlaces(_ url: URL, visits: [Visit]) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let schema = """
            PRAGMA user_version = 78;
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
              visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
              frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL,
              url_hash INTEGER DEFAULT 0 NOT NULL, description TEXT, preview_image_url TEXT, site_name TEXT,
              origin_id INTEGER, recalc_frecency INTEGER NOT NULL DEFAULT 0, alt_frecency INTEGER,
              recalc_alt_frecency INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER,
              visit_type INTEGER, session INTEGER, source INTEGER DEFAULT 0 NOT NULL, triggeringPlaceId INTEGER);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }
        var ids: [String: Int64] = [:]
        for visit in visits where ids[visit.url] == nil {
            let all = visits.filter { $0.url == visit.url }
            var statement: OpaquePointer?
            let insert = "INSERT INTO moz_places(url, title, visit_count, hidden, typed, last_visit_date) VALUES(?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, visit.url, -1, transient)
            sqlite3_bind_text(statement, 2, visit.title, -1, transient)
            sqlite3_bind_int(statement, 3, Int32(all.filter { ![4, 7, 8, 9].contains($0.type) }.count))
            sqlite3_bind_int(statement, 4, visit.hidden ? 1 : 0)
            sqlite3_bind_int(statement, 5, all.contains { $0.type == 2 } ? 1 : 0)
            sqlite3_bind_int64(statement, 6, all.map { micros($0.date) }.max() ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            ids[visit.url] = sqlite3_last_insert_rowid(handle)
        }
        var statement: OpaquePointer?
        let insert = "INSERT INTO moz_historyvisits(place_id, visit_date, visit_type, session) VALUES(?, ?, ?, 0)"
        guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        for visit in visits {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, ids[visit.url] ?? 0)
            sqlite3_bind_int64(statement, 2, micros(visit.date))
            sqlite3_bind_int(statement, 3, Int32(visit.type))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Leaves the database open in WAL mode with the rows still in `cookies.sqlite-wal`, as a running Firefox keeps it.
    private static func writeDatabase(_ url: URL, cookies: [Cookie]) throws {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix)) }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let schema = """
            PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; PRAGMA user_version = 17;
            CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT,
              value TEXT, host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER,
              isSecure INTEGER, isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0,
              schemeMap INTEGER DEFAULT 0, isPartitionedAttributeSet INTEGER DEFAULT 0, updateTime INTEGER,
              CONSTRAINT moz_uniqueid UNIQUE (name, host, path, originAttributes));
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        var statement: OpaquePointer?
        let insert = """
            INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, lastAccessed, creationTime,
              isSecure, isHttpOnly, sameSite, schemeMap, updateTime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 2, ?)
            """
        guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, cookie) in cookies.enumerated() {
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000) - Int64(cookies.count - index) * 1_000_000
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, cookie.originAttributes, -1, transient)
            sqlite3_bind_text(statement, 2, cookie.name, -1, transient)
            sqlite3_bind_text(statement, 3, cookie.value, -1, transient)
            sqlite3_bind_text(statement, 4, cookie.host, -1, transient)
            sqlite3_bind_text(statement, 5, cookie.path, -1, transient)
            sqlite3_bind_int64(statement, 6, Int64(cookie.expires.timeIntervalSince1970 * 1000))
            sqlite3_bind_int64(statement, 7, now)
            sqlite3_bind_int64(statement, 8, now)
            sqlite3_bind_int(statement, 9, cookie.secure ? 1 : 0)
            sqlite3_bind_int(statement, 10, cookie.httpOnly ? 1 : 0)
            sqlite3_bind_int(statement, 11, Int32(cookie.sameSite))
            sqlite3_bind_int64(statement, 12, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
        // Closing the last connection would checkpoint the rows into the database; a running Firefox keeps them in
        // the WAL, so the copy must bring it along. Copying the files while the connection is open leaves them there.
        let held = url.deletingLastPathComponent().appending(path: "held")
        try? FileManager.default.removeItem(at: held)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(at: URL(filePath: url.path(percentEncoded: false) + suffix),
                                             to: held.appending(path: url.lastPathComponent + suffix))
        }
        sqlite3_close(handle)
        handle = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix)) }
        for suffix in ["", "-wal"] {
            try FileManager.default.moveItem(at: held.appending(path: url.lastPathComponent + suffix),
                                             to: URL(filePath: url.path(percentEncoded: false) + suffix))
        }
        try FileManager.default.removeItem(at: held)
    }
}
#endif
