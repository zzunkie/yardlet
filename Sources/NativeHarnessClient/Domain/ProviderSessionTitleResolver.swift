import CSQLite
import Foundation

/// Where the title a harness gives its sessions comes from. Both kinds reach the task
/// through the same rules and the same schedule in AppModel; only how a title arrives differs.
enum ProviderTitleSource: Equatable, Sendable {
    /// The attached session announces the title and each announcement is adopted as it arrives.
    /// Codex: the thread's `name` in its presentation, which Codex's own title turn sets with
    /// `thread/name/set` (`CodexThreadTitle`). A detached session is not woken to ask.
    case push
    /// Yardlet reads the title the harness stored, without attaching or resuming the session
    /// (`ProviderSessionTitleResolver`): Grok's `generated_title`, Claude's latest `custom-title`
    /// or else `ai-title`, OpenCode's session database, Kimi's `state.json`. A harness that
    /// stores none reads nothing, and its task keeps the local fallback.
    case pull

    init(harness: HarnessKind) {
        self = harness == .codex ? .push : .pull
    }
}

struct ProviderSessionTitlePaths: Sendable {
    var grokSessionsRoot: URL
    var claudeProjectsRoot: URL
    var openCodeDatabaseURL: URL
    var kimiSessionsRoot: URL
    /// Antigravity CLI's data folder, whose conversation index has the titles it generates.
    var antigravityRoot: URL = AntigravityConversationStore.live.root

    static func live(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        // Kimi Code resolves its data directory from `KIMI_CODE_HOME` before `~/.kimi-code`, Grok
        // Build from `GROK_HOME` before `~/.grok`, and the runtime Yardlet launches inherits this
        // process's environment.
        func folder(_ variable: String, else fallback: String) -> URL {
            environment[variable].flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
                ?? homeURL.appending(path: fallback, directoryHint: .isDirectory)
        }
        let kimiHome = folder("KIMI_CODE_HOME", else: ".kimi-code")
        return Self(
            grokSessionsRoot: folder("GROK_HOME", else: ".grok").appending(path: "sessions", directoryHint: .isDirectory),
            claudeProjectsRoot: homeURL.appending(path: ".claude/projects", directoryHint: .isDirectory),
            openCodeDatabaseURL: homeURL.appending(path: ".local/share/opencode/opencode.db"),
            kimiSessionsRoot: kimiHome.appending(path: "sessions", directoryHint: .isDirectory),
            antigravityRoot: homeURL.appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory)
        )
    }

    /// These places for a task's account: a saved account's harness keeps its history in the
    /// account's own folder (`ProviderConnection.environment`), so a session is read where it was
    /// saved. The default login's stay as found.
    func forAccount(_ connection: ProviderConnection?) -> Self {
        guard let connection, let path = connection.homePath else { return self }
        let home = URL(filePath: path, directoryHint: .isDirectory)
        var paths = self
        switch connection.harness {
        case .grokBuild: paths.grokSessionsRoot = home.appending(path: "sessions", directoryHint: .isDirectory)
        case .claudeCode: paths.claudeProjectsRoot = home.appending(path: "projects", directoryHint: .isDirectory)
        case .openCode: paths.openCodeDatabaseURL = home.appending(path: "data/opencode/opencode.db")
        case .kimiCode: paths.kimiSessionsRoot = home.appending(path: "sessions", directoryHint: .isDirectory)
        default: break
        }
        return paths
    }
}

enum ProviderSessionTitleResolver {
    static func title(
        for session: SessionRecord,
        paths: ProviderSessionTitlePaths = .live()
    ) -> String? {
        guard let providerSessionID = safePathComponent(session.providerSessionID) else { return nil }
        let paths = paths.forAccount(session.connection)
        switch session.harness {
        case .grokBuild:
            return grokTitle(providerSessionID: providerSessionID, root: paths.grokSessionsRoot)
        case .claudeCode:
            return claudeTitle(providerSessionID: providerSessionID, root: paths.claudeProjectsRoot)
        case .openCode:
            return openCodeTitle(providerSessionID: providerSessionID, databaseURL: paths.openCodeDatabaseURL)
        case .kimiCode:
            return kimiTitle(providerSessionID: providerSessionID, root: paths.kimiSessionsRoot)
        case .antigravityCLI:
            // The CLI names a conversation when it starts; a task still on its local stand-in
            // identity has no conversation yet.
            guard UUID(uuidString: providerSessionID) != session.id else { return nil }
            return AntigravityConversationStore(root: paths.antigravityRoot).title(conversationID: providerSessionID)
        default:
            return nil
        }
    }

    private static func grokTitle(providerSessionID: String, root: URL) -> String? {
        guard let summaryURL = uniqueProviderFile(
            root: root,
            relativePath: "\(providerSessionID)/summary.json"
        ),
        let data = boundedData(at: summaryURL, maximumBytes: 1_048_576),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SessionTitleProjection.normalizedProviderTitle(object["generated_title"] as? String)
    }

    /// Claude Code keeps two titles in the transcript and re-appends both as it writes: the name
    /// the person gave the session (`custom-title`) and the one it generated from the first
    /// request (`ai-title`). For each, the latest record wins, so a cleared name stays cleared;
    /// like Claude's own session list, the name comes before the generated title.
    private static func claudeTitle(providerSessionID: String, root: URL) -> String? {
        guard let historyURL = uniqueProviderFile(
            root: root,
            relativePath: "\(providerSessionID).jsonl"
        ),
        let data = boundedData(at: historyURL, maximumBytes: 32 * 1_048_576),
        let contents = String(data: data, encoding: .utf8) else { return nil }
        var customTitle: String??
        var generatedTitle: String??
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed()
            where line.contains("-title\"") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["sessionId"] as? String == providerSessionID else { continue }
            switch object["type"] as? String {
            case "custom-title" where customTitle == nil:
                customTitle = .some(SessionTitleProjection.normalizedProviderTitle(object["customTitle"] as? String))
            case "ai-title" where generatedTitle == nil:
                generatedTitle = .some(SessionTitleProjection.normalizedProviderTitle(object["aiTitle"] as? String))
            default:
                continue
            }
            if case let .some(.some(title)) = customTitle { return title }
            if customTitle != nil, generatedTitle != nil { break }
        }
        return generatedTitle ?? nil
    }

    /// Kimi Code keeps a session in `sessions/<workspace id>/<session id>/` with its metadata in
    /// `state.json`; its newer engine may keep that file under `session-meta/` instead. The title
    /// is read the way Kimi's own session list reads it: the one the user set, otherwise the one
    /// Kimi took from the first prompt. Its "New Session" placeholder is no title at all.
    private static func kimiTitle(providerSessionID: String, root: URL) -> String? {
        guard let stateURL = uniqueProviderFile(
            root: root,
            relativePath: "\(providerSessionID)/state.json"
        ) ?? uniqueProviderFile(
            root: root,
            relativePath: "\(providerSessionID)/session-meta/state.json"
        ),
        let data = boundedData(at: stateURL, maximumBytes: 1_048_576),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title: String?
        if object["isCustomTitle"] is Bool, let current = object["title"] as? String {
            title = current
        } else if let custom = object["customTitle"] as? String {
            title = custom
        } else {
            title = object["title"] as? String
        }
        return SessionTitleProjection.normalizedProviderTitle(title)
    }

    private static func openCodeTitle(
        providerSessionID: String,
        databaseURL: URL
    ) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            return nil
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT title FROM session WHERE id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, providerSessionID, -1, providerTitleSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawTitle = sqlite3_column_text(statement, 0) else { return nil }
        return SessionTitleProjection.normalizedProviderTitle(String(cString: rawTitle))
    }

    /// Grok, Claude and Kimi encode a workspace into the immediate child directory. Resolve exactly
    /// one match so a malformed or reused provider ID can never select an arbitrary history file.
    /// The root itself may be a link (Session Switch links each account's `projects` to
    /// `~/.claude/projects`), which a directory listing does not follow; nothing beneath it is.
    private static func uniqueProviderFile(root: URL, relativePath: String) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let matches = children.compactMap { child -> URL? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let candidate = child.appending(path: relativePath)
            return FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
                ? candidate
                : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func safePathComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\") else { return nil }
        return value
    }
}

private let providerTitleSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
