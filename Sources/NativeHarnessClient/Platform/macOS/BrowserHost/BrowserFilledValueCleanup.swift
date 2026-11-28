import CSQLite
import Darwin
import Foundation

/// Removes, once, what Yardlet and its browser kept of addresses that carried a vault password before the browser
/// refused such addresses (docs/BROWSER_VAULT_DESIGN.md, "Filled values and addresses"): a sign-in form sent by GET
/// put the password the vault filled into the address it went to. Only entries whose address carries a vault
/// item's password go, the whole of a query or fragment value or of a path segment (`Matcher`):
/// - Chromium's history in the default and each task profile (`History`: the address, its visits and what hangs on
///   them, and the visited links of the page; `Favicons`: the page's icon) and in the root's
///   `segmentation_platform/ukm_db`;
/// - each task's saved browser tabs (`Yardlet.taskWorkspace.*`): such a page keeps its site and path, without its
///   query and fragment (only its site when its path carries the value), and loses its title;
/// - the address field's history (`AddressHistory.json` in the root): such a page, and a search for the value.
/// Nothing is backed up, since a copy would keep the password. It runs as Yardlet starts, before the task
/// workspaces and the browser host read these, and only in a team-signed build, whose vault items it can read
/// without asking. Once every store was read and changed it records that in Yardlet's preferences, with how many
/// entries went from each store and no address, and does not run again; a store a running host holds is tried again
/// at the next start.
@MainActor
enum BrowserFilledValueCleanup {
    static let recordKey = "Yardlet.browser.filledValueCleanup"

    struct Record: Codable, Equatable {
        var ranAt: Date
        /// Entries removed from each store that had any: `<profile>/History`, `Task workspaces` …
        var removed: [String: Int]
    }

    enum Outcome: Equatable {
        case alreadyDone
        case notFinished
        case done(Record)
    }

    /// As Yardlet starts: the person's vault passwords from the keychain, never in a test or QA run (whose vault is
    /// in memory) or a build the keychain does not trust with them.
    static func runAtLaunch() async {
        guard NSClassFromString("XCTestCase") == nil, ProcessInfo.processInfo.environment["YARDLET_VAULT_QA"] != "1",
              UserDefaults.yardlet.data(forKey: recordKey) == nil, await MacVault.signingCheck.value else { return }
        guard let passwords = await Task.detached(operation: loadPasswords).value else { return }
        run(root: BrowserHostPaths.standard().root, passwords: passwords, defaults: .yardlet)
    }

    nonisolated private static func loadPasswords() -> [String]? {
        let secrets = KeychainVaultSecretStore.live()
        var passwords: [String] = []
        for item in FileVaultRepository.live().loadItems() {
            let secret: VaultSecret?
            do {
                secret = try secrets.load(item.id)
            } catch {
                // An item the keychain will not give now is tried again at the next start.
                return nil
            }
            if let password = secret?.password { passwords.append(password) }
        }
        return passwords
    }

    @discardableResult
    static func run(root: URL, passwords: [String], defaults: UserDefaults, now: Date = Date()) -> Outcome {
        guard defaults.data(forKey: recordKey) == nil else { return .alreadyDone }
        let matcher = Matcher(passwords: passwords)
        var removed: [String: Int] = [:]
        var finished = true
        if !matcher.isEmpty {
            if hostHoldsProfiles(root: root) { return .notFinished }
            for (name, database) in databases(root: root) {
                guard let count = clean(database, matcher) else {
                    finished = false
                    continue
                }
                if count > 0 { removed[name] = count }
            }
            let workspaces = cleanTaskWorkspaces(defaults, matcher)
            if workspaces > 0 { removed["Task workspaces"] = workspaces }
            switch cleanAddressHistory(root.appending(path: "AddressHistory.json"), matcher) {
            case nil: finished = false
            case let count?: if count > 0 { removed["AddressHistory.json"] = count }
            }
        }
        guard finished else { return .notFinished }
        let record = Record(ranAt: now, removed: removed)
        guard let data = try? JSONEncoder().encode(record) else { return .notFinished }
        defaults.set(data, forKey: recordKey)
        return .done(record)
    }

    /// Whether an address carries a password: a query or fragment parameter's value, or a path segment, that is the
    /// password as written, in base64 or in hex (`VaultScrubList.spellings`), percent-encoded once or twice and in a
    /// query also with `+` for a space. An address inside a parameter (a sign-in page's return address) is looked
    /// into as well. A password only somewhere inside a longer value does not count: a short one would take
    /// unrelated pages with it.
    struct Matcher {
        private let spellings: Set<String>

        init(passwords: [String]) {
            spellings = Set(passwords.filter { $0.count >= VaultScrubList.shortest }.flatMap(VaultScrubList.spellings(of:)))
        }

        var isEmpty: Bool { spellings.isEmpty }

        /// Whether text is a password as a whole: a search's terms.
        func isValue(_ text: String) -> Bool { Self.decodings(of: text).contains(where: spellings.contains) }

        func carries(_ address: String) -> Bool { carries(address, depth: 0) }

        private func carries(_ address: String, depth: Int) -> Bool {
            let (located, fragment) = Self.split(address, at: "#")
            let (beforeQuery, query) = Self.split(located, at: "?")
            let path = beforeQuery.range(of: "://").map { beforeQuery[$0.upperBound...].drop { $0 != "/" } } ?? beforeQuery[...]
            for segment in path.split(separator: "/") where Self.decodings(of: String(segment)).contains(where: spellings.contains) {
                return true
            }
            let parts = [query, fragment].compactMap { $0 }.flatMap { $0.split { $0 == "&" || $0 == ";" } }
            for part in parts {
                let value = String(part.firstIndex(of: "=").map { part[part.index(after: $0)...] } ?? part)
                for decoded in Self.decodings(of: value) {
                    if spellings.contains(decoded) { return true }
                    if depth < 2, decoded != value, decoded.contains("?") || decoded.contains("#"),
                       carries(decoded, depth: depth + 1) { return true }
                }
            }
            return false
        }

        private static func split(_ text: String, at mark: Character) -> (String, String?) {
            guard let index = text.firstIndex(of: mark) else { return (text, nil) }
            return (String(text[..<index]), String(text[text.index(after: index)...]))
        }

        /// The text, and the text with one and two rounds of percent-encoding undone, each with or without `+`
        /// read as a space.
        static func decodings(of text: String) -> Set<String> {
            var found: Set<String> = [text]
            var round: Set<String> = [text]
            for _ in 0..<2 {
                round = Set(round.flatMap { text in
                    [text, text.replacingOccurrences(of: "+", with: " ")].compactMap { $0.removingPercentEncoding }
                })
                found.formUnion(round)
            }
            return found
        }

        /// The address without what carries a password: its query and fragment, or all but its site when its
        /// path does.
        func cleaned(_ address: String) -> String {
            let located = Self.split(Self.split(address, at: "#").0, at: "?").0
            guard carries(located), let scheme = located.range(of: "://") else { return located }
            let site = located[scheme.upperBound...].prefix { $0 != "/" }
            return String(located[..<scheme.upperBound]) + site + "/"
        }
    }

    // MARK: Chromium's databases

    /// The databases that keep addresses, under the names the record uses: each profile's `History` and `Favicons`
    /// and the root's `ukm_db`.
    private static func databases(root: URL) -> [(String, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        let profiles = names.filter { name in
            name == "Default" || (name.hasPrefix(BrowserTaskProfiles.folderPrefix)
                && UUID(uuidString: String(name.dropFirst(BrowserTaskProfiles.folderPrefix.count))) != nil)
        }.sorted()
        var found: [(String, URL)] = []
        for profile in profiles {
            for file in ["History", "Favicons"] { found.append(("\(profile)/\(file)", root.appending(path: "\(profile)/\(file)"))) }
        }
        found.append(("segmentation_platform/ukm_db", root.appending(path: "segmentation_platform/ukm_db")))
        return found.filter { FileManager.default.fileExists(atPath: $0.1.path(percentEncoded: false)) }
    }

    /// Chromium's lock on the root cache names the host that holds it (`<host name>-<pid>`), and stays behind a host
    /// that crashed.
    private static func hostHoldsProfiles(root: URL) -> Bool {
        let lock = root.appending(path: "SingletonLock").path(percentEncoded: false)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = target.split(separator: "-").last.flatMap({ pid_t($0) }), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes the rows that carry a password in one transaction: how many went, nil when the database could not be
    /// read or changed.
    private static func clean(_ database: URL, _ matcher: Matcher) -> Int? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        var tables = Set<String>()
        guard query(handle, "SELECT name FROM sqlite_master WHERE type = 'table'", each: { statement in
            if let name = sqlite3_column_text(statement, 0) { tables.insert(String(cString: name)) }
        }) != nil else { return nil }
        let statements: [String]
        switch database.lastPathComponent {
        case "History": statements = historyDeletes(handle, tables, matcher)
        case "Favicons":
            statements = rows(handle, tables, "icon_mapping", key: "id", columns: ["page_url"], matcher)
                .map { ["DELETE FROM icon_mapping WHERE id IN (\($0))"] } ?? []
        default:
            statements = rows(handle, tables, "urls", key: "url_id", columns: ["url"], matcher).map { ids in
                ["DELETE FROM urls WHERE url_id IN (\(ids))"]
                    + (tables.contains("metrics") ? ["DELETE FROM metrics WHERE url_id IN (\(ids))"] : [])
            } ?? []
        }
        guard !statements.isEmpty else { return 0 }
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
        var changed = 0
        for statement in statements {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                return nil
            }
            changed += Int(sqlite3_changes(handle))
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return nil
        }
        return changed
    }

    /// The history's addresses that carry a password, their visits and what Chromium keeps of either; the visited
    /// links the page was, or had a frame of.
    private static func historyDeletes(_ handle: OpaquePointer?, _ tables: Set<String>, _ matcher: Matcher) -> [String] {
        var deletes: [String] = []
        func delete(_ table: String, _ condition: String) {
            if tables.contains(table) { deletes.append("DELETE FROM \(table) WHERE \(condition)") }
        }
        if let links = rows(handle, tables, "visited_links", key: "id", columns: ["top_level_url", "frame_url"], matcher) {
            delete("visited_links", "id IN (\(links))")
        }
        guard let urls = rows(handle, tables, "urls", key: "id", columns: ["url"], matcher) else { return deletes }
        var visits: [Int64] = []
        _ = query(handle, "SELECT id FROM visits WHERE url IN (\(urls))") { visits.append(sqlite3_column_int64($0, 0)) }
        let visitIDs = visits.map(String.init).joined(separator: ",")
        if !visitIDs.isEmpty {
            delete("visit_source", "id IN (\(visitIDs))")
            delete("content_annotations", "visit_id IN (\(visitIDs))")
            delete("context_annotations", "visit_id IN (\(visitIDs))")
            delete("clusters_and_visits", "visit_id IN (\(visitIDs))")
            delete("cluster_visit_duplicates", "visit_id IN (\(visitIDs)) OR duplicate_visit_id IN (\(visitIDs))")
        }
        delete("visits", "url IN (\(urls))")
        delete("keyword_search_terms", "url_id IN (\(urls))")
        delete("segment_usage", "segment_id IN (SELECT id FROM segments WHERE url_id IN (\(urls)))")
        delete("segments", "url_id IN (\(urls))")
        delete("visited_links", "link_url_id IN (\(urls))")
        delete("urls", "id IN (\(urls))")
        return deletes
    }

    /// The keys, joined for `IN (…)`, of a table's rows whose address columns carry a password; nil when none do or
    /// the table is not there.
    private static func rows(_ handle: OpaquePointer?, _ tables: Set<String>, _ table: String, key: String,
                             columns: [String], _ matcher: Matcher) -> String? {
        guard tables.contains(table) else { return nil }
        var keys: [Int64] = []
        _ = query(handle, "SELECT \(key), \(columns.joined(separator: ", ")) FROM \(table)") { statement in
            let carries = columns.indices.contains { index in
                sqlite3_column_text(statement, Int32(index + 1)).map { matcher.carries(String(cString: $0)) } ?? false
            }
            if carries { keys.append(sqlite3_column_int64(statement, 0)) }
        }
        return keys.isEmpty ? nil : keys.map(String.init).joined(separator: ",")
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

    // MARK: Yardlet's own records

    /// The address field's history (`BrowserAddressHistory`), edited in place: how many pages and searches went, nil
    /// when the file is there but could not be read or written.
    private static func cleanAddressHistory(_ file: URL, _ matcher: Matcher) -> Int? {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return 0 }
        guard let data = try? Data(contentsOf: file),
              var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let pages = saved["pages"] as? [[String: Any]] ?? []
        let searches = saved["searches"] as? [[String: Any]] ?? []
        let keptPages = pages.filter { !matcher.carries($0["url"] as? String ?? "") }
        let keptSearches = searches.filter { !matcher.isValue($0["terms"] as? String ?? "") }
        let removed = pages.count - keptPages.count + searches.count - keptSearches.count
        guard removed > 0 else { return 0 }
        saved["pages"] = keptPages
        saved["searches"] = keptSearches
        guard let rewritten = try? JSONSerialization.data(withJSONObject: saved),
              (try? rewritten.write(to: file, options: .atomic)) != nil else { return nil }
        return removed
    }

    // MARK: Task workspaces

    /// Each task's saved browser tabs (`UserDefaultsTaskWorkspaceRepository`), edited in place so fields of a later
    /// build stay: how many pages changed.
    private static func cleanTaskWorkspaces(_ defaults: UserDefaults, _ matcher: Matcher) -> Int {
        let prefix = "Yardlet.taskWorkspace."
        var changed = 0
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = value as? Data,
                  var snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var browser = snapshot["browser"] as? [String: Any] else { continue }
            var pagesChanged = 0
            if let address = browser["address"] as? String, matcher.carries(address) {
                browser["address"] = matcher.cleaned(address)
                pagesChanged += 1
            }
            if let tabs = browser["tabs"] as? [String] {
                browser["tabs"] = tabs.map { matcher.carries($0) ? matcher.cleaned($0) : $0 }
                pagesChanged += tabs.filter(matcher.carries).count
            }
            if let pages = browser["pages"] as? [[String: Any]] {
                browser["pages"] = pages.map { page in
                    guard let address = page["address"] as? String, matcher.carries(address) else { return page }
                    pagesChanged += 1
                    var page = page
                    page["address"] = matcher.cleaned(address)
                    page["title"] = ""
                    return page
                }
            }
            guard pagesChanged > 0 else { continue }
            snapshot["browser"] = browser
            guard let rewritten = try? JSONSerialization.data(withJSONObject: snapshot) else { continue }
            defaults.set(rewritten, forKey: key)
            changed += pagesChanged
        }
        return changed
    }
}
