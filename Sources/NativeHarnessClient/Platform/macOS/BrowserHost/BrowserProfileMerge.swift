import CSQLite
import Foundation

/// Fills the default profile, once, with the sites that task profiles from before tasks shared it hold and it has no
/// cookie of, so a sign-in made only in one of those tasks is not lost when the task moves to the default profile and
/// its folder goes (docs/BROWSER_SESSION_ISOLATION.md 7). Rows go over as Chromium stored them: the same browser
/// encrypted every profile's values with one key, bound to the row's host and not its profile. A site the default
/// profile has an unexpired, unpartitioned cookie of stays as it is, and of several profiles that hold one site, the
/// profile that used it last gives it; partitioned cookies stay behind. It runs before the browser host starts, which
/// holds the databases open, and first copies the default profile's `Cookies` to a folder in the Trash.
enum BrowserProfileMerge {
    struct Outcome: Equatable {
        /// Keys whose cookies could not be read or taken (another table, a database that does not open): their tasks
        /// keep their profiles.
        var unread: Set<String>
        /// The sites the default profile took, each with the key it came from.
        var sites: [String: String]
    }

    /// Nil when a browser host holds the profiles, or the default profile could not be read, backed up or opened: it
    /// runs again at the next start.
    static func fill(root: URL, from keys: [String], trash: URL, now: Date = Date()) -> Outcome? {
        guard !BrowserCookieCopyRepair.hostHoldsProfiles(root: root) else { return nil }
        let target = root.appending(path: "Default/Cookies")
        let time = chromiumTime(now)
        // Without a database of its own the default profile takes nothing, and every profile with cookies stays.
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            let holding = keys.filter { key in
                FileManager.default.fileExists(atPath: database(root, key).path(percentEncoded: false))
                    && sites(in: database(root, key), at: time)?.isEmpty != true
            }
            return Outcome(unread: Set(holding), sites: [:])
        }
        guard let present = sites(in: target, at: time) else { return nil }
        var unread = Set<String>()
        // Each site the default profile lacks, from the profile that used it last, with that profile's hosts of it.
        var chosen: [String: (key: String, used: Int64, hosts: [String])] = [:]
        for key in keys {
            guard let held = sites(in: database(root, key), at: time) else {
                if FileManager.default.fileExists(atPath: database(root, key).path(percentEncoded: false)) { unread.insert(key) }
                continue
            }
            for (site, use) in held where !present.keys.contains(site) && use.used > chosen[site]?.used ?? .min {
                chosen[site] = (key, use.used, use.hosts)
            }
        }
        guard !chosen.isEmpty else { return Outcome(unread: unread, sites: [:]) }
        let backups = trash.appending(path: "Yardlet cookie backup \(BrowserCookieCopyRepair.backupTime(now))", directoryHint: .isDirectory)
        guard BrowserCookieCopyRepair.backUp(target, to: backups.appending(path: "Default", directoryHint: .isDirectory)) else {
            return nil
        }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(target.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        var taken: [String: String] = [:]
        for key in Set(chosen.values.map(\.key)).sorted() {
            let sites = chosen.filter { $0.value.key == key }
            if insert(sites.flatMap(\.value.hosts), from: database(root, key), into: handle, at: time) {
                for site in sites.keys { taken[site] = key }
            } else {
                unread.insert(key)
            }
        }
        return Outcome(unread: unread, sites: taken)
    }

    private static func database(_ root: URL, _ key: String) -> URL {
        root.appending(path: "\(BrowserTaskProfiles.folderPrefix)\(key)/Cookies")
    }

    /// Chromium's time: microseconds since 1601.
    private static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns: Set = ["host_key", "top_frame_site_key", "expires_utc", "has_expires", "last_access_utc"]
    private static let unexpired = "top_frame_site_key = '' AND (has_expires = 0 OR expires_utc > ?1)"

    /// The sites a database has unexpired, unpartitioned cookies of, each with its hosts and when it was used last; nil
    /// when it does not open or lacks the columns.
    private static func sites(in database: URL, at time: Int64) -> [String: (used: Int64, hosts: [String])]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              columns.isSubset(of: tableColumns(handle, "main")) else { return nil }
        sqlite3_busy_timeout(handle, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT host_key, MAX(last_access_utc) FROM cookies WHERE \(unexpired) GROUP BY host_key",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, time)
        var sites: [String: (used: Int64, hosts: [String])] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let host = String(cString: text)
                let site = BrowserLoginImport.site(of: host)
                var known = sites[site] ?? (.min, [])
                known.used = max(known.used, sqlite3_column_int64(statement, 1))
                known.hosts.append(host)
                sites[site] = known
            case SQLITE_DONE:
                return sites
            default:
                return nil
            }
        }
    }

    private static func tableColumns(_ handle: OpaquePointer?, _ schema: String) -> [String] {
        var names: [String] = []
        _ = BrowserCookieCopyRepair.query(handle, "PRAGMA \(schema).table_info(cookies)") { statement in
            if let name = sqlite3_column_text(statement, 1) { names.append(String(cString: name)) }
        }
        return names
    }

    /// Copies the rows of these hosts from `source` into the open default profile in one transaction; false when the
    /// tables differ or nothing could be taken.
    private static func insert(_ hosts: [String], from source: URL, into handle: OpaquePointer?, at time: Int64) -> Bool {
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "ATTACH DATABASE ?1 AS source", -1, &attach, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(attach, 1, source.path(percentEncoded: false), -1, transient)
        let attached = sqlite3_step(attach) == SQLITE_DONE
        sqlite3_finalize(attach)
        guard attached else { return false }
        defer { sqlite3_exec(handle, "DETACH DATABASE source", nil, nil, nil) }
        // Rows go column for column, and a value is read as the version that wrote it.
        var versions: [String] = []
        for schema in ["main", "source"] {
            _ = BrowserCookieCopyRepair.query(handle, "SELECT value FROM \(schema).meta WHERE key = 'version'") { statement in
                versions.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            }
        }
        let names = tableColumns(handle, "main")
        guard !names.isEmpty, names == tableColumns(handle, "source"), versions.count == 2, versions[0] == versions[1] else {
            return false
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT OR IGNORE INTO main.cookies SELECT * FROM source.cookies WHERE host_key = ?2 AND "
                                 + unexpired, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        for host in hosts {
            sqlite3_bind_int64(statement, 1, time)
            sqlite3_bind_text(statement, 2, host, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                return false
            }
            sqlite3_reset(statement)
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return false
        }
        return true
    }
}
