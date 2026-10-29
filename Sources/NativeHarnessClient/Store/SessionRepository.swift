import CSQLite
import Foundation

protocol SessionRepository: Sendable {
    func loadSessions() async throws -> [SessionRecord]
    /// Saves a task's fields. An archived or deleted task stays archived or deleted, so a save
    /// that finishes after the task was archived cannot bring it back; `unarchive` does that.
    func upsert(_ session: SessionRecord) async throws
    func archive(id: UUID) async throws
    /// Archives a task the person can restore later. `providerArchived` records that the
    /// provider's own thread was archived too, so restoring knows to unarchive it there.
    func archive(id: UUID, providerArchived: Bool) async throws
    /// Archived tasks, most recently archived first.
    func loadArchivedSessions() async throws -> [ArchivedSessionRecord]
    /// Returns an archived task to the index exactly as it was archived, or nil when it is not
    /// archived (already restored, deleted, or never there).
    func unarchive(id: UUID) async throws -> SessionRecord?
    /// Takes a task out of the index without listing it under archived tasks: a deleted task,
    /// or one that a failed fork, import, or side chat created and then gave up on.
    func discard(id: UUID) async throws
    /// The context usage each task in the index last showed (`TaskContextUsageSnapshot`).
    func loadContextUsage() async throws -> [UUID: TaskContextUsageSnapshot]
    /// Keeps what a task's context usage shows now, beside its row. It is not activity: the task's
    /// other fields, its place and its last activity stay as they are.
    func saveContextUsage(_ snapshot: TaskContextUsageSnapshot, for id: UUID) async throws
    /// Every provider session the index has a row for, listed, archived or deleted
    /// (`SessionListFollow`): a conversation once in Yardlet is not brought in again by itself.
    func indexedProviderSessions() async throws -> Set<SessionListFollow.IndexedSession>
}

/// The additions are optional for the small test repositories that only exercise the index.
extension SessionRepository {
    func archive(id: UUID, providerArchived: Bool) async throws {
        try await archive(id: id)
    }

    func loadArchivedSessions() async throws -> [ArchivedSessionRecord] { [] }

    func unarchive(id: UUID) async throws -> SessionRecord? { nil }

    func discard(id: UUID) async throws {
        try await archive(id: id)
    }

    func loadContextUsage() async throws -> [UUID: TaskContextUsageSnapshot] { [:] }

    func saveContextUsage(_ snapshot: TaskContextUsageSnapshot, for id: UUID) async throws {}

    /// The small test repositories know no deleted rows: the listed and archived ones.
    func indexedProviderSessions() async throws -> Set<SessionListFollow.IndexedSession> {
        let records = try await loadSessions() + loadArchivedSessions().map(\.session)
        return Set(records.compactMap { record in
            record.providerSessionID.map { SessionListFollow.IndexedSession(harness: record.harness, providerSessionID: $0) }
        })
    }
}

/// An archived task as the index keeps it: the record itself, unchanged, and what archiving did.
struct ArchivedSessionRecord: Identifiable, Hashable, Sendable {
    let session: SessionRecord
    /// When Yardlet archived it. Tasks archived before this was recorded have none.
    let archivedAt: Date?
    /// Whether archiving also archived the provider's thread (Codex `thread/archive`). Tasks
    /// archived before this was recorded read as false, so restoring them never calls the
    /// provider.
    let isProviderArchived: Bool

    var id: UUID { session.id }
}

enum SessionRepositoryError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case invalidRow(String)
}

actor SQLiteSessionRepository: SessionRepository {
    private let databaseURL: URL
    private let connection = SQLiteConnection()

    private var database: OpaquePointer? {
        get { connection.pointer }
        set { connection.pointer = newValue }
    }

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func loadSessions() async throws -> [SessionRecord] {
        try ensureOpen()
        let statement = try prepare("""
            SELECT \(Self.recordColumns)
            FROM sessions
            WHERE archived = \(IndexState.active.rawValue)
            ORDER BY updated_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        var sessions: [SessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sessions.append(try record(from: statement))
        }
        return sessions
    }

    func loadArchivedSessions() async throws -> [ArchivedSessionRecord] {
        try ensureOpen()
        // Rows archived before `archived_at` existed fall back to their last activity.
        let statement = try prepare("""
            SELECT \(Self.recordColumns), archived_at, provider_archived
            FROM sessions
            WHERE archived = \(IndexState.archived.rawValue)
            ORDER BY COALESCE(archived_at, updated_at) DESC;
            """)
        defer { sqlite3_finalize(statement) }
        let archivedAt = Self.recordColumnCount
        var archived: [ArchivedSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            archived.append(ArchivedSessionRecord(
                session: try record(from: statement),
                archivedAt: sqlite3_column_type(statement, archivedAt) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, archivedAt)),
                isProviderArchived: sqlite3_column_int(statement, archivedAt + 1) != 0
            ))
        }
        return archived
    }

    /// `archived` is 0 for a task in the index, 1 for an archived task, and 2 for a deleted or
    /// discarded one. Rows deleted before 2 existed read as archived.
    private enum IndexState: Int32 {
        case active = 0
        case archived = 1
        case discarded = 2
    }

    /// The columns `record(from:)` reads, in order.
    private static let recordColumns = """
        id, harness, workspace_path, runtime_path, title, status,
        created_at, updated_at, provider_session_id, unread, completion_state,
        environment_scope, pinned, title_origin, provider_options, inherited_context, connection_binding,
        project_id, additional_roots, origin_workspace_path, worktree_name, branch, parent_task_id,
        lineage_detached
        """
    private static let recordColumnCount: Int32 = 24

    private func record(from statement: OpaquePointer) throws -> SessionRecord {
        let harnessValue = text(statement, column: 1)
        guard let id = UUID(uuidString: text(statement, column: 0)),
              !harnessValue.isEmpty,
              let status = SessionStatus(rawValue: text(statement, column: 5)) else {
            throw SessionRepositoryError.invalidRow("Invalid session identity or enum value")
        }
        let harness = HarnessKind(rawValue: harnessValue)
        let providerSessionID = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil
            : text(statement, column: 8)
        let hasUnreadUpdate = sqlite3_column_int(statement, 9) != 0
        let completionState = SessionCompletionState(rawValue: text(statement, column: 10)) ?? .none
        let environmentScope = SessionEnvironmentScope(rawValue: text(statement, column: 11)) ?? .native
        let isPinned = sqlite3_column_int(statement, 12) != 0
        let titleOrigin = SessionTitleOrigin(rawValue: text(statement, column: 13)) ?? .legacy
        let providerOptions = decodeProviderOptions(text(statement, column: 14))
        let inheritedContext = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil
            : try JSONDecoder().decode(SideChatContext.self, from: Data(text(statement, column: 15).utf8))
        return SessionRecord(
            id: id,
            harness: harness,
            workspaceURL: URL(filePath: text(statement, column: 2)),
            runtimeExecutableURL: URL(filePath: text(statement, column: 3)),
            title: text(statement, column: 4),
            titleOrigin: titleOrigin,
            status: status,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            providerSessionID: providerSessionID,
            hasUnreadUpdate: hasUnreadUpdate,
            completionState: completionState,
            isPinned: isPinned,
            providerOptions: providerOptions,
            environmentScope: environmentScope,
            inheritedContext: inheritedContext,
            connection: sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil
                : try JSONDecoder().decode(ProviderConnection.self, from: Data(text(statement, column: 16).utf8)),
            projectID: sqlite3_column_type(statement, 17) == SQLITE_NULL
                ? nil
                : UUID(uuidString: text(statement, column: 17)),
            additionalRoots: decodeAdditionalRoots(
                sqlite3_column_type(statement, 18) == SQLITE_NULL ? "" : text(statement, column: 18)
            ),
            originWorkspacePath: optionalText(statement, column: 19),
            worktreeName: optionalText(statement, column: 20),
            branch: optionalText(statement, column: 21),
            parentTaskID: optionalText(statement, column: 22).flatMap(UUID.init(uuidString:)),
            isLineageDetached: sqlite3_column_int(statement, 23) != 0
        )
    }

    func upsert(_ session: SessionRecord) async throws {
        try ensureOpen()
        let sql = """
            INSERT INTO sessions (
                id, harness, workspace_path, runtime_path, title, status,
                created_at, updated_at, provider_session_id, unread, completion_state,
                environment_scope, pinned, title_origin, provider_options, inherited_context, connection_binding,
                project_id, additional_roots, origin_workspace_path, worktree_name, branch, parent_task_id,
                lineage_detached, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET
                harness = excluded.harness,
                workspace_path = excluded.workspace_path,
                runtime_path = excluded.runtime_path,
                title = excluded.title,
                status = excluded.status,
                updated_at = excluded.updated_at,
                provider_session_id = excluded.provider_session_id,
                unread = excluded.unread,
                completion_state = excluded.completion_state,
                environment_scope = excluded.environment_scope,
                pinned = excluded.pinned,
                title_origin = excluded.title_origin,
                provider_options = excluded.provider_options,
                inherited_context = excluded.inherited_context,
                connection_binding = excluded.connection_binding,
                project_id = excluded.project_id,
                additional_roots = excluded.additional_roots,
                origin_workspace_path = excluded.origin_workspace_path,
                worktree_name = excluded.worktree_name,
                branch = excluded.branch,
                parent_task_id = excluded.parent_task_id,
                lineage_detached = excluded.lineage_detached;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(session.id.uuidString, to: 1, in: statement)
        bind(session.harness.rawValue, to: 2, in: statement)
        bind(session.workspaceURL.path(percentEncoded: false), to: 3, in: statement)
        bind(session.runtimeExecutableURL.path(percentEncoded: false), to: 4, in: statement)
        bind(session.title, to: 5, in: statement)
        bind(session.status.rawValue, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, session.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, session.updatedAt.timeIntervalSince1970)
        if let providerSessionID = session.providerSessionID {
            bind(providerSessionID, to: 9, in: statement)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_int(statement, 10, session.hasUnreadUpdate ? 1 : 0)
        bind(session.completionState.rawValue, to: 11, in: statement)
        bind(session.environmentScope.rawValue, to: 12, in: statement)
        sqlite3_bind_int(statement, 13, session.isPinned ? 1 : 0)
        bind(session.titleOrigin.rawValue, to: 14, in: statement)
        bind(encodeProviderOptions(session.providerOptions), to: 15, in: statement)
        if let context = session.inheritedContext {
            bind(String(decoding: try JSONEncoder().encode(context), as: UTF8.self), to: 16, in: statement)
        } else { sqlite3_bind_null(statement, 16) }
        if let connection = session.connection {
            bind(String(decoding: try JSONEncoder().encode(connection), as: UTF8.self), to: 17, in: statement)
        } else { sqlite3_bind_null(statement, 17) }
        if let projectID = session.projectID {
            bind(projectID.uuidString, to: 18, in: statement)
        } else { sqlite3_bind_null(statement, 18) }
        if session.additionalRoots.isEmpty {
            sqlite3_bind_null(statement, 19)
        } else {
            bind(encodeAdditionalRoots(session.additionalRoots), to: 19, in: statement)
        }
        bindOptional(session.originWorkspacePath, to: 20, in: statement)
        bindOptional(session.worktreeName, to: 21, in: statement)
        bindOptional(session.branch, to: 22, in: statement)
        bindOptional(session.parentTaskID?.uuidString, to: 23, in: statement)
        sqlite3_bind_int(statement, 24, session.isLineageDetached ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
    }

    func archive(id: UUID) async throws {
        try await archive(id: id, providerArchived: false)
    }

    func archive(id: UUID, providerArchived: Bool) async throws {
        try ensureOpen()
        let statement = try prepare("""
            UPDATE sessions SET archived = \(IndexState.archived.rawValue), archived_at = ?, provider_archived = ?
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, providerArchived ? 1 : 0)
        bind(id.uuidString, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
    }

    func unarchive(id: UUID) async throws -> SessionRecord? {
        try ensureOpen()
        let update = try prepare("""
            UPDATE sessions SET archived = \(IndexState.active.rawValue), archived_at = NULL, provider_archived = 0
            WHERE id = ? AND archived = \(IndexState.archived.rawValue);
            """)
        defer { sqlite3_finalize(update) }
        bind(id.uuidString, to: 1, in: update)
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
        guard sqlite3_changes(database) == 1 else { return nil }
        let select = try prepare("SELECT \(Self.recordColumns) FROM sessions WHERE id = ?;")
        defer { sqlite3_finalize(select) }
        bind(id.uuidString, to: 1, in: select)
        guard sqlite3_step(select) == SQLITE_ROW else { return nil }
        return try record(from: select)
    }

    func discard(id: UUID) async throws {
        try ensureOpen()
        let statement = try prepare("UPDATE sessions SET archived = \(IndexState.discarded.rawValue) WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
    }

    /// Rows in the index with a value this build reads; another value reads as none.
    func loadContextUsage() async throws -> [UUID: TaskContextUsageSnapshot] {
        try ensureOpen()
        let statement = try prepare("""
            SELECT id, context_usage FROM sessions
            WHERE archived = \(IndexState.active.rawValue) AND context_usage IS NOT NULL;
            """)
        defer { sqlite3_finalize(statement) }
        var usage: [UUID: TaskContextUsageSnapshot] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)),
                  let snapshot = optionalText(statement, column: 1).flatMap(TaskContextUsageSnapshot.decoded)
            else { continue }
            usage[id] = snapshot
        }
        return usage
    }

    func saveContextUsage(_ snapshot: TaskContextUsageSnapshot, for id: UUID) async throws {
        try ensureOpen()
        let statement = try prepare("UPDATE sessions SET context_usage = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(try TaskContextUsageSnapshot.encoded(snapshot), to: 1, in: statement)
        bind(id.uuidString, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
    }

    func indexedProviderSessions() async throws -> Set<SessionListFollow.IndexedSession> {
        try ensureOpen()
        let statement = try prepare("""
            SELECT harness, provider_session_id FROM sessions
            WHERE provider_session_id IS NOT NULL AND provider_session_id != '';
            """)
        defer { sqlite3_finalize(statement) }
        var indexed = Set<SessionListFollow.IndexedSession>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let harness = text(statement, column: 0)
            guard !harness.isEmpty else { continue }
            indexed.insert(SessionListFollow.IndexedSession(harness: HarnessKind(rawValue: harness),
                                                            providerSessionID: text(statement, column: 1)))
        }
        return indexed
    }

    private func ensureOpen() throws {
        guard database == nil else { return }
        let result = sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = errorMessage()
            sqlite3_close(database)
            database = nil
            throw SessionRepositoryError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 2_000)
        try migrate()
    }

    private func migrate() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY NOT NULL,
                harness TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                provider_session_id TEXT,
                unread INTEGER NOT NULL DEFAULT 0,
                completion_state TEXT NOT NULL DEFAULT 'none',
                environment_scope TEXT NOT NULL DEFAULT 'native',
                pinned INTEGER NOT NULL DEFAULT 0,
                title_origin TEXT NOT NULL DEFAULT 'legacy',
                archived INTEGER NOT NULL DEFAULT 0,
                provider_options TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS sessions_workspace_updated
                ON sessions(workspace_path, updated_at DESC);
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
        try addColumnIfMissing(name: "unread", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(name: "completion_state", definition: "TEXT NOT NULL DEFAULT 'none'")
        try addColumnIfMissing(name: "environment_scope", definition: "TEXT NOT NULL DEFAULT 'native'")
        try addColumnIfMissing(name: "pinned", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(name: "title_origin", definition: "TEXT NOT NULL DEFAULT 'legacy'")
        try addColumnIfMissing(name: "provider_options", definition: "TEXT NOT NULL DEFAULT '{}'")
        try addColumnIfMissing(name: "inherited_context", definition: "TEXT")
        try addColumnIfMissing(name: "connection_binding", definition: "TEXT")
        // Projects arrived after these rows existed. Existing tasks keep a null project and an
        // empty root list and are matched to a project by their cwd when the sidebar renders.
        try addColumnIfMissing(name: "project_id", definition: "TEXT")
        try addColumnIfMissing(name: "additional_roots", definition: "TEXT")
        // Worktree origin arrived later still. Existing rows keep these null: Yardlet does not
        // rescan saved folders on launch, so a row only gains an origin when its task is opened.
        try addColumnIfMissing(name: "origin_workspace_path", definition: "TEXT")
        try addColumnIfMissing(name: "worktree_name", definition: "TEXT")
        try addColumnIfMissing(name: "branch", definition: "TEXT")
        // Archive details arrived with restoring archived tasks. Rows archived earlier keep a
        // null date and read as not archived in the provider.
        try addColumnIfMissing(name: "archived_at", definition: "REAL")
        try addColumnIfMissing(name: "provider_archived", definition: "INTEGER NOT NULL DEFAULT 0")
        // The task a task was started from arrived with nesting in the sidebar. Existing rows keep
        // it null (top level) until a link is read for them; an earlier build ignores the column
        // and its saves leave it as it is.
        try addColumnIfMissing(name: "parent_task_id", definition: "TEXT")
        // "Detach to top level" arrived later. Existing rows read as not detached; an earlier build
        // ignores the column and its saves leave it as it is.
        try addColumnIfMissing(name: "lineage_detached", definition: "INTEGER NOT NULL DEFAULT 0")
        // What the context ring last showed arrived with showing it after a restart. Existing rows
        // keep it null until the task reports or its history is read; an earlier build ignores the
        // column, and no save of the task's fields (`upsert`) writes it.
        try addColumnIfMissing(name: "context_usage", definition: "TEXT")
    }

    private func addColumnIfMissing(name: String, definition: String) throws {
        let statement = try prepare("PRAGMA table_info(sessions);")
        defer { sqlite3_finalize(statement) }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, column: 1) == name {
                exists = true
                break
            }
        }
        guard !exists else { return }
        let sql = "ALTER TABLE sessions ADD COLUMN \(name) \(definition);"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SessionRepositoryError.statementFailed(errorMessage())
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column: column)
    }

    private func errorMessage() -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }

    private func encodeProviderOptions(_ options: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func encodeAdditionalRoots(_ roots: [String]) -> String {
        guard let data = try? JSONEncoder().encode(roots) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeAdditionalRoots(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let roots = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return roots
    }

    private func decodeProviderOptions(_ value: String) -> [String: String] {
        guard let data = value.data(using: .utf8),
              let options = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return options
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    var pointer: OpaquePointer?

    deinit {
        sqlite3_close(pointer)
    }
}

actor InMemorySessionRepository: SessionRepository {
    private var sessions: [UUID: SessionRecord] = [:]
    private var contextUsage: [UUID: TaskContextUsageSnapshot] = [:]
    private var archived: [UUID: (at: Date, providerArchived: Bool)] = [:]
    private var discarded: Set<UUID> = []

    /// `archived` are the IDs among `sessions` that start archived.
    init(sessions: [SessionRecord] = [], archived: [UUID] = []) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let now = Date()
        self.archived = Dictionary(uniqueKeysWithValues: archived.enumerated().map {
            ($0.element, (at: now.addingTimeInterval(-Double($0.offset) * 600), providerArchived: false))
        })
    }

    func loadSessions() async throws -> [SessionRecord] {
        sessions.values
            .filter { archived[$0.id] == nil && !discarded.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ session: SessionRecord) async throws {
        sessions[session.id] = session
    }

    func archive(id: UUID) async throws {
        try await archive(id: id, providerArchived: false)
    }

    func archive(id: UUID, providerArchived: Bool) async throws {
        guard sessions[id] != nil else { return }
        archived[id] = (Date(), providerArchived)
    }

    func loadArchivedSessions() async throws -> [ArchivedSessionRecord] {
        archived.compactMap { id, entry in
            sessions[id].map {
                ArchivedSessionRecord(session: $0, archivedAt: entry.at, isProviderArchived: entry.providerArchived)
            }
        }
        .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    func unarchive(id: UUID) async throws -> SessionRecord? {
        guard archived.removeValue(forKey: id) != nil else { return nil }
        return sessions[id]
    }

    func discard(id: UUID) async throws {
        archived.removeValue(forKey: id)
        discarded.insert(id)
    }

    func loadContextUsage() async throws -> [UUID: TaskContextUsageSnapshot] {
        contextUsage.filter { sessions[$0.key] != nil && archived[$0.key] == nil && !discarded.contains($0.key) }
    }

    func saveContextUsage(_ snapshot: TaskContextUsageSnapshot, for id: UUID) async throws {
        guard sessions[id] != nil else { return }
        contextUsage[id] = snapshot
    }

    /// Every row, deleted ones included, as the SQLite index keeps them.
    func indexedProviderSessions() async throws -> Set<SessionListFollow.IndexedSession> {
        Set(sessions.values.compactMap { record in
            record.providerSessionID.map { SessionListFollow.IndexedSession(harness: record.harness, providerSessionID: $0) }
        })
    }
}
