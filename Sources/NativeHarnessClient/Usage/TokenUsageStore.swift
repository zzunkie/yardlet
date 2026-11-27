import Foundation
import CSQLite

/// The counts Settings › Usage keeps, in one SQLite file in its own folder (`~/.yardlet/usage/`):
/// tokens and API-equivalent cost by day, harness, model, session, folder and account, and those of the
/// turns schedules' runs started by day and schedule; how far each transcript has been read; and the
/// responses counted in the last two weeks, so one copied into a forked conversation is not counted
/// again. Only `TokenUsageLedger` opens it, from its own actor.
final class TokenUsageStore {
    /// One row of counts, as `usage` keeps it.
    struct Row: Equatable, Sendable {
        var day: Int
        var harness: String
        var model: String
        var session: String
        var folder: String
        var account: String
        var amount: TokenUsageAmount
    }

    /// One day of a schedule's counts, as `schedule_usage` keeps it: the requests of the turns its runs started,
    /// which `usage` counts as well.
    struct ScheduleRow: Equatable, Sendable {
        var day: Int
        var schedule: String
        var amount: TokenUsageAmount
    }

    struct FileState: Equatable, Sendable {
        var inode: UInt64
        var offset: UInt64
        var carry: Data?
    }

    private var database: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw Self.error(database)
        }
        try execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL, offset INTEGER NOT NULL,
                carry BLOB);
            CREATE TABLE IF NOT EXISTS usage(day INTEGER NOT NULL, harness TEXT NOT NULL, model TEXT NOT NULL,
                session TEXT NOT NULL, folder TEXT NOT NULL, account TEXT NOT NULL, \(Self.amountColumns),
                PRIMARY KEY(day, harness, model, session, folder, account));
            CREATE TABLE IF NOT EXISTS schedule_usage(day INTEGER NOT NULL, schedule TEXT NOT NULL, \(Self.amountColumns),
                PRIMARY KEY(day, schedule));
            CREATE TABLE IF NOT EXISTS seen(hash INTEGER PRIMARY KEY, output INTEGER NOT NULL, day INTEGER NOT NULL);
            """)
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: Reading

    func fileStates() throws -> [String: FileState] {
        var states: [String: FileState] = [:]
        try query("SELECT path, inode, offset, carry FROM files") { statement in
            let carry = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil
                : Data(bytes: sqlite3_column_blob(statement, 3), count: Int(sqlite3_column_bytes(statement, 3)))
            states[Self.text(statement, 0)] = FileState(
                inode: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                offset: UInt64(bitPattern: sqlite3_column_int64(statement, 2)), carry: carry)
        }
        return states
    }

    /// The output counted for each response seen since `day`.
    func seen(since day: Int) throws -> [Int64: Int64] {
        var seen: [Int64: Int64] = [:]
        try query("SELECT hash, output FROM seen WHERE day >= \(day)") { statement in
            seen[sqlite3_column_int64(statement, 0)] = sqlite3_column_int64(statement, 1)
        }
        return seen
    }

    func rows(since day: Int) throws -> [Row] {
        var rows: [Row] = []
        try query("""
            SELECT day, harness, model, session, folder, account, \(Self.amountNames) FROM usage WHERE day >= \(day)
            """) { statement in
            rows.append(Row(day: Int(sqlite3_column_int64(statement, 0)), harness: Self.text(statement, 1),
                            model: Self.text(statement, 2), session: Self.text(statement, 3),
                            folder: Self.text(statement, 4), account: Self.text(statement, 5),
                            amount: Self.amount(statement, from: 6)))
        }
        return rows
    }

    func scheduleRows(since day: Int) throws -> [ScheduleRow] {
        var rows: [ScheduleRow] = []
        try query("SELECT day, schedule, \(Self.amountNames) FROM schedule_usage WHERE day >= \(day)") { statement in
            rows.append(ScheduleRow(day: Int(sqlite3_column_int64(statement, 0)), schedule: Self.text(statement, 1),
                                    amount: Self.amount(statement, from: 2)))
        }
        return rows
    }

    // MARK: Writing

    /// Adds the rows and the schedules' rows, records the responses seen and where each file was read to, all at once.
    func apply(rows: [Row], scheduleRows: [ScheduleRow], seen: [(hash: Int64, output: Int64, day: Int)],
               files: [String: FileState]) throws {
        try execute("BEGIN")
        do {
            try prepared("""
                INSERT INTO usage VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, harness, model, session, folder, account) DO UPDATE SET \(Self.addingAmounts)
                """) { statement in
                for row in rows {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, Int64(row.day))
                    for (index, text) in [row.harness, row.model, row.session, row.folder, row.account].enumerated() {
                        sqlite3_bind_text(statement, Int32(index + 2), text, -1, Self.transient)
                    }
                    Self.bind(row.amount, to: statement, from: 7)
                    try step(statement)
                }
            }
            try prepared("""
                INSERT INTO schedule_usage VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, schedule) DO UPDATE SET \(Self.addingAmounts)
                """) { statement in
                for row in scheduleRows {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, Int64(row.day))
                    sqlite3_bind_text(statement, 2, row.schedule, -1, Self.transient)
                    Self.bind(row.amount, to: statement, from: 3)
                    try step(statement)
                }
            }
            try prepared("INSERT OR REPLACE INTO seen VALUES(?, ?, ?)") { statement in
                for entry in seen {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, entry.hash)
                    sqlite3_bind_int64(statement, 2, entry.output)
                    sqlite3_bind_int64(statement, 3, Int64(entry.day))
                    try step(statement)
                }
            }
            try prepared("INSERT OR REPLACE INTO files VALUES(?, ?, ?, ?)") { statement in
                for (path, state) in files {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, path, -1, Self.transient)
                    sqlite3_bind_int64(statement, 2, Int64(bitPattern: state.inode))
                    sqlite3_bind_int64(statement, 3, Int64(bitPattern: state.offset))
                    if let carry = state.carry {
                        _ = carry.withUnsafeBytes { buffer in
                            sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), Self.transient)
                        }
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    try step(statement)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Drops counts from before `usageDay` and responses seen before `seenDay`.
    func prune(usageBefore usageDay: Int, seenBefore seenDay: Int) throws {
        try execute("""
            DELETE FROM usage WHERE day < \(usageDay); DELETE FROM schedule_usage WHERE day < \(usageDay);
            DELETE FROM seen WHERE day < \(seenDay);
            """)
    }

    // MARK: Amounts

    /// The columns of a `TokenUsageAmount` in both count tables: tokens of each kind, requests, the cost of each
    /// kind, and whether any of it had a price.
    private static let amountColumns = """
        fresh INTEGER NOT NULL, write INTEGER NOT NULL, read INTEGER NOT NULL, output INTEGER NOT NULL,
        requests INTEGER NOT NULL, cost_fresh REAL NOT NULL, cost_write REAL NOT NULL, cost_read REAL NOT NULL,
        cost_output REAL NOT NULL, priced INTEGER NOT NULL
        """
    private static let amountNames = "fresh, write, read, output, requests, cost_fresh, cost_write, cost_read, cost_output, priced"
    /// A count added to the row it falls in.
    private static let addingAmounts = """
        fresh = fresh + excluded.fresh, write = write + excluded.write, read = read + excluded.read,
        output = output + excluded.output, requests = requests + excluded.requests,
        cost_fresh = cost_fresh + excluded.cost_fresh, cost_write = cost_write + excluded.cost_write,
        cost_read = cost_read + excluded.cost_read, cost_output = cost_output + excluded.cost_output,
        priced = priced + excluded.priced
        """

    /// The amount in the ten columns from `first`, in the order of `amountNames`.
    private static func amount(_ statement: OpaquePointer, from first: Int32) -> TokenUsageAmount {
        var amount = TokenUsageAmount(
            freshInput: sqlite3_column_int64(statement, first), cacheWrite: sqlite3_column_int64(statement, first + 1),
            cacheRead: sqlite3_column_int64(statement, first + 2), output: sqlite3_column_int64(statement, first + 3),
            requests: Int(sqlite3_column_int64(statement, first + 4)))
        if sqlite3_column_int64(statement, first + 9) > 0 {
            amount.kindCost = [.freshInput: sqlite3_column_double(statement, first + 5),
                               .cacheWrite: sqlite3_column_double(statement, first + 6),
                               .cacheRead: sqlite3_column_double(statement, first + 7),
                               .output: sqlite3_column_double(statement, first + 8)]
        }
        return amount
    }

    /// Binds the amount to the ten parameters from `first` (counted from 1), in the order of `amountNames`.
    private static func bind(_ amount: TokenUsageAmount, to statement: OpaquePointer, from first: Int32) {
        for (index, value) in [amount.freshInput, amount.cacheWrite, amount.cacheRead, amount.output,
                               Int64(amount.requests)].enumerated() {
            sqlite3_bind_int64(statement, first + Int32(index), value)
        }
        for (index, kind) in [TokenUsageKind.freshInput, .cacheWrite, .cacheRead, .output].enumerated() {
            sqlite3_bind_double(statement, first + 5 + Int32(index), amount.kindCost[kind] ?? 0)
        }
        sqlite3_bind_int64(statement, first + 9, amount.kindCost.isEmpty ? 0 : 1)
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(database) }
    }

    private func prepared(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.error(database)
        }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func query(_ sql: String, _ row: (OpaquePointer) -> Void) throws {
        try prepared(sql) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw Self.error(database) }
                row(statement)
            }
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(database) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func error(_ database: OpaquePointer?) -> NSError {
        NSError(domain: "TokenUsageStore", code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
