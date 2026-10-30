import CSQLite
import Foundation

/// Antigravity CLI's own conversation files, read and never written (docs/NATIVE_SESSION_STORAGE.md,
/// "Antigravity"):
///
/// - `conversation_summaries.db`, the index `agy`'s `/resume` lists: one row per conversation with
///   its title, preview, folder (`workspace_uris`), times and `parent_conversation_id`. Rows whose
///   `app_data_dir` is `antigravity` are the desktop app's (its `~/.gemini/antigravity`), which the
///   CLI copies into its own store before it continues one, so they are not offered.
/// - `cache/last_conversations.json`, the folder each `agy` run last continued, for rows the CLI
///   recorded without a folder.
/// - `brain/<id>/.system_generated/logs/transcript_full.jsonl` (else `transcript.jsonl`), the
///   conversation's readable log: requests, answers, thinking and tool calls.
///
/// The index is a SQLite file in WAL mode that `agy` may be writing; opening it read-only could still
/// create its `-wal`/`-shm` files, so it is read from a private copy that is removed at once.
struct AntigravityConversationStore: Sendable {
    let root: URL

    static var live: AntigravityConversationStore {
        AntigravityConversationStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory))
    }

    /// The largest index and log Yardlet reads.
    static let maximumIndexBytes = 64 << 20
    static let maximumTranscriptBytes = 8 << 20

    struct Summary: Equatable, Sendable {
        let conversationID: String
        let title: String
        let preview: String
        let stepCount: Int
        let updatedAt: Date?
        let workspaceURL: URL?
        let parentConversationID: String?
        let nestingDepth: Int
        let appDataDirectory: String
    }

    // MARK: - Listing

    /// Every conversation the CLI can continue by its ID: its own (`antigravity-cli`), not a
    /// subagent's (`nesting_depth` 0), with steps, and with a known folder. Newest first.
    func conversations() throws -> [ImportableConversation] {
        let lastByFolder = lastConversationFolders()
        return try summaries()
            .filter { $0.appDataDirectory == "antigravity-cli" && $0.nestingDepth == 0 && $0.stepCount > 0 }
            .compactMap { summary -> ImportableConversation? in
                guard let folder = summary.workspaceURL ?? lastByFolder[summary.conversationID] else { return nil }
                return ImportableConversation(
                    harness: .antigravityCLI,
                    providerSessionID: summary.conversationID,
                    title: Self.title(of: summary),
                    workspaceURL: folder,
                    updatedAt: summary.updatedAt ?? .distantPast,
                    isOpenElsewhere: false,
                    parentProviderSessionID: summary.parentConversationID)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The conversations of one folder, newest first.
    func conversations(in folder: URL, limit: Int = 50) throws -> [ImportableConversation] {
        let target = Self.path(folder)
        return Array(try conversations().filter { Self.path($0.workspaceURL) == target }.prefix(limit))
    }

    /// The title the CLI generated for a conversation, for the task's title.
    func title(conversationID: String) -> String? {
        guard let summary = try? summaries().first(where: { $0.conversationID == conversationID }),
              !summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SessionTitleProjection.normalizedProviderTitle(summary.title)
    }

    func summaries() throws -> [Summary] {
        let index = root.appending(path: "conversation_summaries.db")
        guard Self.isRegularFile(index, maximumBytes: Self.maximumIndexBytes) else { return [] }
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-antigravity-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: copy) }
        let database = copy.appending(path: "conversation_summaries.db")
        try FileManager.default.copyItem(at: index, to: database)
        let wal = root.appending(path: "conversation_summaries.db-wal")
        if Self.isRegularFile(wal, maximumBytes: Self.maximumIndexBytes) {
            try? FileManager.default.copyItem(at: wal, to: copy.appending(path: "conversation_summaries.db-wal"))
        }
        return try Self.readSummaries(databaseURL: database)
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
        // Only the columns read here; a newer CLI may add others.
        let sql = """
            SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
                   parent_conversation_id, nesting_depth, app_data_dir
            FROM conversation_summaries
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AntigravityConversationStoreError.unreadableIndex
        }
        defer { sqlite3_finalize(statement) }
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
                updatedAt: date(text(4)),
                workspaceURL: firstFolder(in: text(5)),
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
            guard let id = value as? String, folder.hasPrefix("/") else { continue }
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

    /// `["file:///Users/…/project"]` → that folder.
    static func firstFolder(in workspaceURIs: String) -> URL? {
        guard let data = workspaceURIs.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        for value in values {
            guard let url = URL(string: value), url.isFileURL, url.path(percentEncoded: false).hasPrefix("/") else { continue }
            return URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory).standardizedFileURL
        }
        return nil
    }

    /// `2026-10-16 05:41:41.331209+00:00`, as the index stores it.
    static func date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx",
                       "yyyy-MM-dd'T'HH:mm:ssxxx"] {
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(Self.maximumTranscriptBytes) ? size - UInt64(Self.maximumTranscriptBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        // A cut first line is dropped.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        return AntigravityTranscript(
            entries: AntigravityTranscriptParser.entries(conversationID: conversationID, jsonl: data),
            stamp: stamp)
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
                        input: StructuredHeadlessEventProjector.antigravityToolInput(call["args"]))
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

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
