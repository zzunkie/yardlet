import CSQLite
import Foundation

/// Antigravity CLI's own conversation files, read and never written (docs/NATIVE_SESSION_STORAGE.md,
/// "Antigravity"):
///
/// - `conversation_summaries.db`, the index `agy`'s `/resume` lists: one row per conversation with
///   its title, preview, folders (`workspace_uris`), times and `parent_conversation_id`. Rows whose
///   `app_data_dir` is `antigravity` are the desktop app's (its `~/.gemini/antigravity`), which the
///   CLI copies into its own store before it continues one, so they are not offered.
/// - `cache/last_conversations.json`, the folder each `agy` run last continued, which names the
///   folder of such a conversation (`ownFolder`) when Yardlet did not start it.
/// - `brain/<id>/.system_generated/logs/transcript_full.jsonl` (else `transcript.jsonl`), the
///   conversation's readable log: requests, answers, thinking and tool calls.
/// - `brain/<id>/.system_generated/subagents/<subagent's conversation ID>.json`, the subagents the
///   conversation started. Each has its own `brain/<id>/` and log.
///
/// The index is a SQLite file in WAL mode that `agy` may be writing; opening it read-only could still
/// create its `-wal`/`-shm` files, so it is read from a private copy that is removed at once.
struct AntigravityConversationStore: Sendable {
    let root: URL

    static var live: AntigravityConversationStore {
        AntigravityConversationStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory))
    }

    /// The largest log tail Yardlet reads into memory. The SQLite summary index is queried by
    /// SQLite without loading the whole file into memory, so it is not capped at a fixed size.
    static let maximumTranscriptBytes = 8 << 20

    struct Summary: Equatable, Sendable {
        let conversationID: String
        let title: String
        let preview: String
        let stepCount: Int
        let updatedAt: Date?
        /// `workspace_uris`, in its order: the folder the conversation ran in, with its `--add-dir` folders,
        /// or, for one an `agy acp` process ran, every folder that process served, sorted, so its own
        /// folder need not be the first.
        let workspaceURLs: [URL]
        let parentConversationID: String?
        let nestingDepth: Int
        let appDataDirectory: String
    }

    // MARK: - Listing

    /// Every conversation the CLI can continue by its ID: its own (`antigravity-cli`), not a
    /// subagent's (`nesting_depth` 0), with steps, and with a known folder: its own (`ownFolder`), else
    /// the first it lists. Newest first. `startedByYardlet` is the folder Yardlet opened each conversation
    /// it started in, by the conversation ID in lower case.
    func conversations(startedByYardlet: [String: URL] = [:]) throws -> [ImportableConversation] {
        let lastByFolder = lastConversationFolders()
        return try continuableSummaries().compactMap { summary -> ImportableConversation? in
            guard let folder = Self.ownFolder(of: summary,
                                              startedIn: startedByYardlet[summary.conversationID.lowercased()],
                                              lastContinuedIn: lastByFolder[summary.conversationID])
                    ?? summary.workspaceURLs.first else { return nil }
            return Self.importable(summary, in: folder)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The conversations of one folder, newest first: those whose own folder it is, and those whose own
    /// folder is not known that list it among theirs.
    func conversations(in folder: URL, startedByYardlet: [String: URL] = [:],
                       limit: Int = 50) throws -> [ImportableConversation] {
        let target = Self.path(folder)
        let lastByFolder = lastConversationFolders()
        return Array(try continuableSummaries().filter { summary in
            if let own = Self.ownFolder(of: summary,
                                        startedIn: startedByYardlet[summary.conversationID.lowercased()],
                                        lastContinuedIn: lastByFolder[summary.conversationID]) {
                return Self.path(own) == target
            }
            return summary.workspaceURLs.contains { Self.path($0) == target }
        }
        .map { Self.importable($0, in: URL(filePath: target, directoryHint: .isDirectory)) }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(limit))
    }

    private func continuableSummaries() throws -> [Summary] {
        try withIndexDatabase { handle in
            try Self.readSummaries(handle: handle, onlyContinuable: true)
        } ?? []
    }

    private static func importable(_ summary: Summary, in folder: URL) -> ImportableConversation {
        ImportableConversation(
            harness: .antigravityCLI,
            providerSessionID: summary.conversationID,
            title: title(of: summary),
            workspaceURL: folder,
            updatedAt: summary.updatedAt ?? .distantPast,
            isOpenElsewhere: false,
            parentProviderSessionID: summary.parentConversationID)
    }

    /// The folder a conversation ran in, when it is known: the one Yardlet opened it in, for one Yardlet
    /// started (a task's, a subagent's), the one `agy` last continued it in
    /// (`cache/last_conversations.json`), or the only one it lists. A conversation of a shared `agy acp`
    /// process lists every folder the process served, so one Yardlet has no record of is found in each.
    static func ownFolder(of summary: Summary, startedIn: URL?, lastContinuedIn: URL?) -> URL? {
        startedIn ?? lastContinuedIn ?? (summary.workspaceURLs.count == 1 ? summary.workspaceURLs.first : nil)
    }

    /// The title the CLI generated for a conversation, for the task's title.
    func title(conversationID: String) -> String? {
        let id = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let raw: String? = (try? withIndexDatabase { handle in
            let sql = "SELECT title FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw AntigravityConversationStoreError.unreadableIndex
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let pointer = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: pointer)
        }) ?? nil
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SessionTitleProjection.normalizedProviderTitle(raw)
    }

    func summaries() throws -> [Summary] {
        try withIndexDatabase { handle in
            try Self.readSummaries(handle: handle, onlyContinuable: false)
        } ?? []
    }

    private func withIndexDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T? {
        let index = root.appending(path: "conversation_summaries.db")
        guard Self.isRegularFile(index, maximumBytes: Int.max) else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-antigravity-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: copy) }
        let database = copy.appending(path: "conversation_summaries.db")
        try FileManager.default.copyItem(at: index, to: database)
        let wal = root.appending(path: "conversation_summaries.db-wal")
        if Self.isRegularFile(wal, maximumBytes: Int.max) {
            try? FileManager.default.copyItem(at: wal, to: copy.appending(path: "conversation_summaries.db-wal"))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw AntigravityConversationStoreError.unreadableIndex
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    static func readSummaries(databaseURL: URL) throws -> [Summary] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw AntigravityConversationStoreError.unreadableIndex
        }
        defer { sqlite3_close(handle) }
        return try readSummaries(handle: handle, onlyContinuable: false)
    }

    private static func readSummaries(handle: OpaquePointer, onlyContinuable: Bool) throws -> [Summary] {
        // Only the columns read here; a newer CLI may add others.
        let filter = onlyContinuable ? " WHERE app_data_dir = 'antigravity-cli' AND nesting_depth = 0 AND step_count > 0" : ""
        let sql = """
            SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
                   parent_conversation_id, nesting_depth, app_data_dir
            FROM conversation_summaries\(filter)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AntigravityConversationStoreError.unreadableIndex
        }
        defer { sqlite3_finalize(statement) }
        let formatter = Self.makeDateFormatter()
        var rows: [Summary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let id = text(0).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.contains("/") else { continue }
            let parent = text(6).trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(Summary(
                conversationID: id,
                title: text(1),
                preview: text(2),
                stepCount: Int(sqlite3_column_int64(statement, 3)),
                updatedAt: date(text(4), using: formatter),
                workspaceURLs: folders(in: text(5)),
                parentConversationID: parent.isEmpty || parent == id ? nil : parent,
                nestingDepth: Int(sqlite3_column_int64(statement, 7)),
                appDataDirectory: text(8)))
        }
        return rows
    }

    /// `cache/last_conversations.json`: `{folder: conversation ID}`, inverted.
    func lastConversationFolders() -> [String: URL] {
        let url = root.appending(path: "cache/last_conversations.json")
        guard Self.isRegularFile(url, maximumBytes: 4 << 20),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var folders: [String: URL] = [:]
        for (folder, value) in object {
            guard let id = value as? String, PathRules.current.isAbsolute(folder) else { continue }
            folders[id] = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
        }
        return folders
    }

    private static func title(of summary: Summary) -> String {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let preview = summary.preview.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preview.isEmpty ? L10n.string("Antigravity conversation") : String(preview.prefix(120))
    }

    /// `["file:///Users/…/project", "file:///tmp"]` → those folders, in order.
    static func folders(in workspaceURIs: String) -> [URL] {
        guard let data = workspaceURIs.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return values.compactMap { value in
            guard let url = URL(string: value), url.isFileURL,
                  PathRules.current.isAbsolute(url.path(percentEncoded: false)) else { return nil }
            return URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory).standardizedFileURL
        }
    }

    /// `2026-10-16 05:41:41.331209+00:00`, as the index stores it.
    static func date(_ value: String) -> Date? {
        date(value, using: makeDateFormatter())
    }

    private static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd'T'HH:mm:ssxxx"
    ]

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func date(_ value: String, using formatter: DateFormatter) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return nil }
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - The conversation's log

    /// The log file of a conversation: the untruncated one where the CLI keeps it.
    func transcriptURL(conversationID: String) -> URL? {
        guard Self.isSafeComponent(conversationID) else { return nil }
        let logs = root.appending(path: "brain/\(conversationID)/.system_generated/logs", directoryHint: .isDirectory)
        for name in ["transcript_full.jsonl", "transcript.jsonl"] {
            let url = logs.appending(path: name)
            if Self.isRegularFile(url, maximumBytes: Int.max) { return url }
        }
        return nil
    }

    /// The conversation as transcript entries, from the newest `maximumTranscriptBytes` of its log.
    func readTranscript(conversationID: String) throws -> AntigravityTranscript {
        guard let url = transcriptURL(conversationID: conversationID) else {
            throw AntigravityConversationStoreError.missingTranscript
        }
        let stamp = DetachedConversationStamp(file: url)
        return AntigravityTranscript(
            entries: AntigravityTranscriptParser.entries(conversationID: conversationID, jsonl: try Self.newestLines(of: url)),
            stamp: stamp)
    }

    /// The whole lines of the newest `maximumTranscriptBytes` of a log.
    private static func newestLines(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumTranscriptBytes) ? size - UInt64(maximumTranscriptBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        // A cut first line is dropped.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        return data
    }

    // MARK: - Subagents

    /// A subagent `agy` started for a conversation (`brain/<id>/.system_generated/subagents/<child>.json`).
    struct Subagent: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case running
            case completed
            case stopped
        }

        let conversationID: String
        let role: String?
        let typeName: String?
        let status: Status
        let startedAt: Date?
        let spawnStepIndex: Int?

        var displayTitle: String {
            let trimmedRole = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedRole.isEmpty { return trimmedRole }
            let trimmedType = typeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedType.isEmpty { return trimmedType }
            return L10n.format("Subagent %@", String(conversationID.prefix(8)))
        }
    }

    /// The subagents `agy` recorded under `conversationID`, in spawn order.
    func subagents(of conversationID: String) -> [Subagent] {
        guard Self.isSafeComponent(conversationID) else { return [] }
        let directory = root.appending(path: "brain/\(conversationID)/.system_generated/subagents",
                                       directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        var result: [Subagent] = []
        for url in files where url.pathExtension == "json" {
            guard Self.isRegularFile(url, maximumBytes: 1 << 20),
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let childID = record["conversationId"]?.stringValue,
                  Self.isSafeComponent(childID) else { continue }
            let descriptor = record["subagentDescriptor"]
            let role = descriptor?["role"]?.stringValue
            let typeName = descriptor?["typeName"]?.stringValue
            let state = record["state"]?.stringValue ?? ""
            let spawnStep = record["spawnStepIndex"]?.integerValue.map(Int.init)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let startedAt = values?.creationDate ?? values?.contentModificationDate
            let atRest = transcriptURL(conversationID: childID).map(Self.lastRecordIsAtRest(of:)) ?? false
            let status: Subagent.Status = if atRest {
                .completed
            } else if state == "SUBAGENT_STATE_KILLED" {
                .stopped
            } else {
                .running
            }
            result.append(Subagent(conversationID: childID, role: role, typeName: typeName,
                                   status: status, startedAt: startedAt, spawnStepIndex: spawnStep))
        }
        return result.sorted { left, right in
            let leftDate = left.startedAt ?? .distantPast
            let rightDate = right.startedAt ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            if (left.spawnStepIndex ?? 0) != (right.spawnStepIndex ?? 0) {
                return (left.spawnStepIndex ?? 0) < (right.spawnStepIndex ?? 0)
            }
            return left.conversationID < right.conversationID
        }
    }

    /// Whether `childConversationID` is recorded as a subagent of `parentConversationID`.
    func hasSubagent(_ childConversationID: String, of parentConversationID: String) -> Bool {
        guard Self.isSafeComponent(parentConversationID), Self.isSafeComponent(childConversationID) else { return false }
        let file = root.appending(
            path: "brain/\(parentConversationID)/.system_generated/subagents/\(childConversationID).json"
        )
        return Self.isRegularFile(file, maximumBytes: 1 << 20)
    }

    /// Whether the log's last non-empty record is a finished `PLANNER_RESPONSE` with no tool calls,
    /// reading only the tail of the file so polling stays O(1).
    private static func lastRecordIsAtRest(of url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let tailWindow: UInt64 = 64 * 1024
        let start = size > tailWindow ? size - tailWindow : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let lastLine = data.split(separator: 0x0A, omittingEmptySubsequences: true).last,
              let record = try? JSONDecoder().decode(JSONValue.self, from: Data(lastLine)) else { return false }
        return record["type"]?.stringValue == "PLANNER_RESPONSE"
            && record["status"]?.stringValue?.uppercased() == "DONE"
            && (record["tool_calls"]?.arrayValue?.isEmpty ?? true)
    }

    // MARK: - What its tools made

    /// A picture `generate_image` saved.
    struct GeneratedImage: Equatable, Sendable {
        let url: URL
        let createdAt: Date?
    }

    /// The pictures the conversation's `generate_image` calls saved, oldest first. The CLI runs that tool in an
    /// `image-generator` subagent whose activity reaches no ACP update, so the record is the log of the conversation
    /// or of a subagent it started. Only the tool's own result counts, and only for a file directly in the
    /// conversation's own folder, where the CLI saves them. A path in a message is the model's word, and the rest of
    /// that folder (its logs and the tools' full output) is not the task's to hand out.
    func generatedImages(conversationID: String) -> [GeneratedImage] {
        guard Self.isSafeComponent(conversationID) else { return [] }
        let folder = root.appending(path: "brain/\(conversationID)", directoryHint: .isDirectory)
        let subagents = (try? FileManager.default.contentsOfDirectory(
            at: folder.appending(path: ".system_generated/subagents", directoryHint: .isDirectory),
            includingPropertiesForKeys: nil)) ?? []
        let conversations = [conversationID] + subagents.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
        var images: [GeneratedImage] = []
        for conversation in conversations {
            guard let log = transcriptURL(conversationID: conversation),
                  let lines = try? Self.newestLines(of: log) else { continue }
            images += AntigravityTranscriptParser.generatedImages(jsonl: lines).filter {
                Self.path($0.url.deletingLastPathComponent()) == Self.path(folder)
            }
        }
        return images.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    // MARK: - Files

    static func isRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return false }
        return size <= maximumBytes
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private static func path(_ url: URL) -> String {
        let value = url.standardizedFileURL.path(percentEncoded: false)
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

enum AntigravityConversationStoreError: LocalizedError, Equatable {
    case unreadableIndex
    case missingTranscript

    var errorDescription: String? {
        switch self {
        case .unreadableIndex: L10n.string("Antigravity's conversation list could not be read.")
        case .missingTranscript: L10n.string("Antigravity has no readable history for this conversation.")
        }
    }
}

/// The log a detached Antigravity task last read, and whether the conversation it shows is that log.
struct AntigravityHistoryShown: Equatable, Sendable {
    let providerSessionID: String
    let stamp: DetachedConversationStamp
    let showsLog: Bool
}

struct AntigravityTranscript: Equatable, Sendable {
    let entries: [TranscriptEntry]
    let stamp: DetachedConversationStamp?

    var requestCount: Int {
        entries.reduce(0) { count, entry in
            if case .user = entry.content { return count + 1 }
            return count
        }
    }
}

/// The log's records as the conversation shows them. A record is
/// `{step_index, type, source, status, created_at, content?, thinking?, tool_calls?, error?, …}`:
/// `USER_INPUT` (the request inside `<USER_REQUEST>`, after which the CLI adds metadata of its own),
/// `PLANNER_RESPONSE` (thinking, tool calls `{name, args}` and the answer), `GENERIC` with status
/// `ERROR` (a tool that failed, after its call), and `SYSTEM_MESSAGE`, which the CLI adds for the
/// model and is not shown. The log has no tool output, so a tool row shows only its call.
enum AntigravityTranscriptParser {
    private static let namespace = UUID(uuidString: "6D1E2A9C-3F4B-4B8E-9C7A-2D5E8F1A0B3C")!

    static func entries(conversationID: String, jsonl: Data) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        // The last response's tool rows by call, and its step: the CLI gives each call's result the
        // step after the response, in call order, and logs only the ones that failed.
        var pendingToolEntryIndices: [Int] = []
        var responseStep: Int64?
        var line = 0
        for raw in jsonl.split(separator: 0x0A, omittingEmptySubsequences: true) {
            line += 1
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(raw)),
                  let type = record["type"]?.stringValue else { continue }
            let step = record["step_index"]?.integerValue.map(String.init) ?? "line-\(line)"
            let createdAt = record["created_at"]?.stringValue.flatMap(isoDate) ?? Date(timeIntervalSince1970: 0)
            func id(_ part: String) -> UUID {
                NameBasedUUID.make(namespace: namespace, name: "\(conversationID)|\(step)|\(part)")
            }
            switch type {
            case "USER_INPUT":
                pendingToolEntryIndices = []
                responseStep = nil
                guard let text = userRequest(record["content"]?.stringValue) else { continue }
                entries.append(TranscriptEntry(id: id("user"), createdAt: createdAt, content: .user(text: text)))
            case "PLANNER_RESPONSE":
                if let thinking = nonEmpty(record["thinking"]?.stringValue) {
                    entries.append(TranscriptEntry(id: id("thinking"), createdAt: createdAt,
                                                   content: .reasoning(text: thinking, isStreaming: false)))
                }
                pendingToolEntryIndices = []
                responseStep = record["step_index"]?.integerValue
                for (index, call) in (record["tool_calls"]?.arrayValue ?? []).enumerated() {
                    let name = call["name"]?.stringValue ?? L10n.string("Agent activity")
                    let activity = HarnessActivity(
                        id: "\(conversationID)-\(step)-\(index)",
                        kind: name,
                        title: name.replacingOccurrences(of: "_", with: " "),
                        detail: call["args"]?["toolSummary"]?.stringValue,
                        input: toolInput(call["args"]))
                    pendingToolEntryIndices.append(entries.count)
                    entries.append(TranscriptEntry(id: id("tool-\(index)"), createdAt: createdAt,
                                                   content: .activity(activity, state: .completed)))
                }
                if let answer = nonEmpty(record["content"]?.stringValue) {
                    entries.append(TranscriptEntry(id: id("answer"), createdAt: createdAt,
                                                   content: .assistant(text: answer, isStreaming: false)))
                }
            case "GENERIC" where record["status"]?.stringValue?.uppercased() == "ERROR":
                let message = nonEmpty(record["error"]?.stringValue) ?? nonEmpty(record["content"]?.stringValue)
                let call: Int? = if let responseStep, let step = record["step_index"]?.integerValue {
                    Int(step - responseStep - 1)
                } else {
                    nil
                }
                if let call, pendingToolEntryIndices.indices.contains(call),
                   case let .activity(activity, _) = entries[pendingToolEntryIndices[call]].content {
                    var failed = activity
                    failed.outcome = .failed
                    failed.output = message
                    entries[pendingToolEntryIndices[call]].content = .activity(failed, state: .failed)
                } else if let message {
                    entries.append(TranscriptEntry(id: id("error"), createdAt: createdAt,
                                                   content: .error(message: message, recoverable: true)))
                }
            default:
                continue
            }
        }
        return entries
    }

    /// What the log's `generate_image` calls saved, by their own results: the record the CLI gives a call, the step
    /// after the response in call order (as in `entries`), when it finished, names the file in its `media`
    /// (`{mime_type, uri}`). Other tools' `media` is what they read, not what they made.
    static func generatedImages(jsonl: Data) -> [AntigravityConversationStore.GeneratedImage] {
        let markers = [Data("generate_image".utf8), Data("\"media\"".utf8)]
        var resultSteps = Set<Int64>()
        var images: [AntigravityConversationStore.GeneratedImage] = []
        for raw in jsonl.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Most of a long log is neither, and is not decoded.
            guard markers.contains(where: { raw.range(of: $0) != nil }),
                  let record = try? JSONDecoder().decode(JSONValue.self, from: Data(raw)),
                  let step = record["step_index"]?.integerValue else { continue }
            switch record["type"]?.stringValue {
            case "PLANNER_RESPONSE":
                for (index, call) in (record["tool_calls"]?.arrayValue ?? []).enumerated()
                where call["name"]?.stringValue == "generate_image" {
                    resultSteps.insert(step + 1 + Int64(index))
                }
            case "GENERIC":
                guard resultSteps.remove(step) != nil, record["status"]?.stringValue?.uppercased() == "DONE" else { continue }
                for media in record["media"]?.arrayValue ?? [] {
                    guard let uri = media["uri"]?.stringValue.flatMap(URL.init(string:)), uri.isFileURL else { continue }
                    images.append(.init(url: URL(filePath: uri.path(percentEncoded: false)),
                                        createdAt: record["created_at"]?.stringValue.flatMap(isoDate)))
                }
            default:
                continue
            }
        }
        return images
    }

    /// The person's request: what `<USER_REQUEST>` holds, without the CLI's own sections after it.
    static func userRequest(_ content: String?) -> String? {
        guard let content else { return nil }
        if let open = content.range(of: "<USER_REQUEST>"),
           let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex) {
            return nonEmpty(String(content[open.upperBound..<close.lowerBound]))
        }
        return nonEmpty(content)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A command's own line where the call has one (`run_command`'s `CommandLine`), otherwise the
    /// arguments as JSON without the summary fields the CLI adds for its own display.
    private static func toolInput(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let command = value["CommandLine"]?.stringValue, !command.isEmpty { return command }
        if case var .object(object) = value {
            object.removeValue(forKey: "toolAction")
            object.removeValue(forKey: "toolSummary")
            return JSONValue.object(object).readableText
        }
        return value.readableText
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
