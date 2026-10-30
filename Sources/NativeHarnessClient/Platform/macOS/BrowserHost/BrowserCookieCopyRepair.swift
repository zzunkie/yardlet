import CSQLite
import Darwin
import Foundation

/// Removes, once per home, the cookies the profile cookie copy left in the wrong form before 2026-10-25
/// (docs/BROWSER_SESSION_ISOLATION.md 8). That copy set every host-only cookie as a domain cookie of its host, which
/// the host still receives but no response of the site's can replace or delete, since the site sets and deletes
/// that name host-only: a site that set it again got two of one name, and Google's accounts site answered with
/// /CookieMismatch; a site that deleted it kept getting it. In the default profile and each task profile, a copied
/// domain cookie (`source_type` 3, set through the cookie manager) goes when a host-only cookie of the same host, name,
/// path and partition is in any of them: that copy never made a host-only cookie, so the host-only one has the
/// site's form even when a later copy carried it. On a host where that finds such cookies, a copied HttpOnly domain
/// cookie with no host-only one anywhere goes too, unless a profile holds it as the site's server set it
/// (`source_type` 1): only a server sets an HttpOnly cookie, and the old copy made that host's domain cookies.
/// The site's own cookies stay. Each `Cookies` database it changes is first copied, with its journal, to a folder in
/// the Trash, and a profile whose copy fails is left as it is. It runs before the browser host starts, which holds the
/// databases open, and leaves `CookieCopyRepair.json` in the root cache with the number it removed from each profile
/// and its round, so it does not run again until a later round. Round 2 (2026-10-26): until then the copy carried a
/// profile's copied domain cookie to another profile beside that site's host-only cookie, so the pairs came back.
/// Round 3 (the same day): pairs of two copies, which round 2 left, as the profiles had passed both between them.
/// Round 4 (2026-10-31): rounds 1 to 3 compared each profile alone, but new tasks' starting cookies and the sign-ins
/// tasks follow had carried the old copy's domain cookies into every profile, often without the site's host-only
/// one, and where none was left anywhere they stayed for good (Porkbun's "Show Password Field" deletes its host-only
/// `npw` cookie and reloads, and its sign-in got two `PPRB` cookies, the old copy's first).
enum BrowserCookieCopyRepair {
    static let recordName = "CookieCopyRepair.json"
    static let round = 4

    struct Record: Codable, Equatable {
        var ranAt: Date
        /// Cookies removed in each profile folder that had any.
        var removed: [String: Int]
        /// nil in the first round's record.
        var round: Int?
    }

    enum Outcome: Equatable {
        case alreadyDone
        /// A browser host holds the profiles, or a profile could not be backed up or changed: it runs again at
        /// the next start.
        case notFinished
        case done(Record)
    }

    /// The Trash of the home Yardlet keeps its data in. FileManager's Trash is the person's even when a QA run
    /// gives Yardlet a home of its own (CFFIXED_USER_HOME, which NSHomeDirectory follows).
    static var trash: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: ".Trash", directoryHint: .isDirectory)
    }

    @discardableResult
    static func runOnce(root: URL, trash: URL, now: Date = Date()) -> Outcome {
        let recordURL = root.appending(path: recordName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: recordURL) {
            // A record this code cannot read is a later round's.
            guard let last = try? decoder.decode(Record.self, from: data), (last.round ?? 1) < round else { return .alreadyDone }
        }
        guard !hostHoldsProfiles(root: root) else { return .notFinished }
        // One profile's cookies can show another's to be the old copy's, so every database is read before any changes.
        var profiles: [(name: String, cookies: [Cookie])] = []
        for name in profileFolders(root: root) {
            guard let cookies = read(root.appending(path: "\(name)/Cookies")) else { return .notFinished }
            profiles.append((name, cookies))
        }
        let isLeftover = leftovers(among: profiles.flatMap { $0.cookies })
        let backups = trash.appending(path: "Yardlet cookie backup \(backupTime(now))", directoryHint: .isDirectory)
        var removed: [String: Int] = [:]
        var finished = true
        for (name, cookies) in profiles {
            let rows = cookies.filter(isLeftover).map(\.row)
            guard !rows.isEmpty else { continue }
            let database = root.appending(path: "\(name)/Cookies")
            guard backUp(database, to: backups.appending(path: name, directoryHint: .isDirectory)),
                  let deleted = remove(rows, from: database) else {
                finished = false
                continue
            }
            if deleted > 0 { removed[name] = deleted }
        }
        guard finished else { return .notFinished }
        let record = Record(ranAt: now, removed: removed, round: round)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(record), (try? data.write(to: recordURL, options: .atomic)) != nil else {
            return .notFinished
        }
        return .done(record)
    }

    /// The backup folder's date and time, local: `2026-10-25 18.30.05`.
    static func backupTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// The default profile and the task profiles (`Task-<UUID>`) with a cookie database.
    private static func profileFolders(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.filter { name in
            guard name == "Default" || (name.hasPrefix(BrowserTaskProfiles.folderPrefix)
                && UUID(uuidString: String(name.dropFirst(BrowserTaskProfiles.folderPrefix.count))) != nil) else { return false }
            return FileManager.default.fileExists(atPath: root.appending(path: "\(name)/Cookies").path(percentEncoded: false))
        }.sorted()
    }

    /// Chromium's lock on the root cache names the host that holds it (`<host name>-<pid>`), and stays behind
    /// a host that crashed.
    private static func hostHoldsProfiles(root: URL) -> Bool {
        let lock = root.appending(path: "SingletonLock").path(percentEncoded: false)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = target.split(separator: "-").last.flatMap({ pid_t($0) }), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// A row of a `Cookies` database, with what the rules weigh.
    private struct Cookie {
        var row: Int64
        /// `host_key`: a domain cookie's starts with a dot.
        var host: String
        var name, path: String
        /// `top_frame_site_key` and `has_cross_site_ancestor`, empty and 0 for an unpartitioned cookie.
        var partition: String
        var crossSiteAncestor: Int
        var httpOnly: Bool
        /// `source_type`: 1 HTTP, 2 script, 3 the cookie manager (a copy).
        var source: Int

        var isDomain: Bool { host.hasPrefix(".") }
        var isCopiedDomainCookie: Bool { isDomain && source == 3 }

        /// The same for a domain cookie and its host's host-only cookie of that name, path and partition.
        var identity: Identity {
            Identity(host: isDomain ? String(host.dropFirst()) : host, name: name, path: path, partition: partition,
                     crossSiteAncestor: crossSiteAncestor)
        }
    }

    private struct Identity: Hashable {
        var host, name, path, partition: String
        var crossSiteAncestor: Int
    }

    /// Which cookies are the old copy's, judged against the cookies of every profile (the type's description).
    private static func leftovers(among cookies: [Cookie]) -> (Cookie) -> Bool {
        let hostOnly = Set(cookies.filter { !$0.isDomain }.map(\.identity))
        let setByServer = Set(cookies.filter { $0.isDomain && $0.source == 1 }.map(\.identity))
        let paired = { (cookie: Cookie) in hostOnly.contains(cookie.identity) }
        let convertedHosts = Set(cookies.filter { $0.isCopiedDomainCookie && paired($0) }.map(\.host))
        return { cookie in
            guard cookie.isCopiedDomainCookie else { return false }
            return paired(cookie) || (cookie.httpOnly && cookie.partition.isEmpty && convertedHosts.contains(cookie.host)
                && !setByServer.contains(cookie.identity))
        }
    }

    /// The database's cookies (none when its table lacks the columns), nil when it cannot be read.
    private static func read(_ database: URL) -> [Cookie]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        var columns = Set<String>()
        guard query(handle, "PRAGMA table_info(cookies)", each: { statement in
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }) != nil else { return nil }
        let needed: Set = ["host_key", "name", "path", "top_frame_site_key", "has_cross_site_ancestor", "is_httponly",
                           "source_type"]
        guard needed.isSubset(of: columns) else { return [] }
        var cookies: [Cookie] = []
        let text = { (statement: OpaquePointer?, column: Int32) in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        guard query(handle, "SELECT rowid, host_key, name, path, top_frame_site_key, has_cross_site_ancestor, is_httponly, "
                    + "source_type FROM cookies", each: { statement in
            cookies.append(Cookie(row: sqlite3_column_int64(statement, 0), host: text(statement, 1), name: text(statement, 2),
                                  path: text(statement, 3), partition: text(statement, 4),
                                  crossSiteAncestor: Int(sqlite3_column_int64(statement, 5)),
                                  httpOnly: sqlite3_column_int64(statement, 6) != 0,
                                  source: Int(sqlite3_column_int64(statement, 7))))
        }) != nil else { return nil }
        return cookies
    }

    /// Copies the database and its journal into `folder` (a new one), true once every file is there.
    private static func backUp(_ database: URL, to folder: URL) -> Bool {
        var destination = folder
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent) \(number)")
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for suffix in ["", "-journal", "-wal"] {
                let file = database.deletingLastPathComponent().appending(path: database.lastPathComponent + suffix)
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
                try FileManager.default.copyItem(at: file, to: destination.appending(path: file.lastPathComponent))
            }
            return true
        } catch {
            return false
        }
    }

    /// Deletes these rows in one transaction: how many went, nil when nothing changed.
    private static func remove(_ rows: [Int64], from database: URL) -> Int? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM cookies WHERE rowid = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
        var deleted = 0
        for row in rows {
            sqlite3_bind_int64(statement, 1, row)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                return nil
            }
            deleted += Int(sqlite3_changes(handle))
            sqlite3_reset(statement)
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return nil
        }
        return deleted
    }

    /// Runs `sql`, calling `each` for every row: the number of rows, nil on an error.
    private static func query(_ handle: OpaquePointer?, _ sql: String, each: (OpaquePointer?) -> Void) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                each(statement)
                rows += 1
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
