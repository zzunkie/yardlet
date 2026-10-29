import Foundation

/// The Code sessions the Claude desktop app keeps, read from the file it writes for each one:
/// `claude-code-sessions/<organization>/<account>/local_<id>.json` in its Application Support
/// folder. The files are the app's own and undocumented, so they are only read, each within a size
/// limit, and any key may be missing. The conversation itself is the Claude Code transcript the
/// session names (`cliSessionId`), which is the provider session ID Yardlet keeps.
enum ClaudeDesktopSessionCatalog {
    /// A session file is a few hundred kilobytes; anything far larger is not read.
    static let maximumFileBytes = 4 * 1_048_576
    static let maximumFiles = 2_000

    /// One session file's fields that importing uses.
    struct Session: Equatable, Sendable {
        let cliSessionID: String
        let title: String?
        let workspaceURL: URL
        /// The repository a worktree session was started from (`originCwd`), only when the
        /// session runs in a folder inside it, as the app's `<repo>/.claude/worktrees/<name>` do.
        let originWorkspaceURL: URL?
        let worktreeName: String?
        let branch: String?
        /// The full model ID (for example `claude-opus-5-5`), the effort level and the permission
        /// mode, in the app's own spelling.
        let model: String?
        let effort: String?
        let permissionMode: String?
        let isArchived: Bool
        let lastActivityAt: Date?
        /// The app's own ID for the session (`sessionId`, `local_…`), which links name.
        var desktopSessionID: String? = nil
        /// The session this one nests under in the app's sidebar, by the app's ID: the session that
        /// started it (`spawnedFrom.sessionId`), else the one it was forked from
        /// (`forkedFromSessionId`), as the app's sidebar picks it. Nil once the person moved it to
        /// top level (`lineageDetached`).
        var startedFromDesktopSessionID: String? = nil
        var isCloud: Bool = false
        var cloudURL: String? = nil
    }

    static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory)
    }

    /// One session file, or nil when it names no CLI session or folder. Only the top-level keys
    /// below are read; a value of an unexpected type counts as missing.
    static func session(from data: Data) -> Session? {
        // `JSONSerialization` reads a few hundred files of a few hundred kilobytes each in a
        // fraction of the time decoding every nested value would take.
        guard data.count <= maximumFileBytes,
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = text(value["cliSessionId"]), UUID(uuidString: id) != nil,
              let cwd = text(value["cwd"]), cwd.hasPrefix("/") else { return nil }
        let workspace = URL(filePath: cwd, directoryHint: .isDirectory).standardizedFileURL
        let origin = text(value["originCwd"]).flatMap { path -> URL? in
            guard path.hasPrefix("/") else { return nil }
            let origin = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            let base = ProjectSidebarPresentation.normalizedPath(for: origin)
            let folder = ProjectSidebarPresentation.normalizedPath(for: workspace)
            return folder.hasPrefix(base == "/" ? "/" : base + "/") && folder != base ? origin : nil
        }
        let activity = (value["lastActivityAt"] as? NSNumber).flatMap { number -> Date? in
            // A JSON boolean is an NSNumber too; it is not a time.
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        let desktopID = text(value["sessionId"])
        let isCloud = (value["isCloud"] as? Bool) == true
            || (value["isRemote"] as? Bool) == true
            || text(value["environment"])?.lowercased() == "cloud"
            || desktopID?.hasPrefix("cloud_") == true
            || desktopID?.hasPrefix("remote_") == true
        let cloudURL = text(value["webUrl"]) ?? text(value["url"])
        return Session(
            cliSessionID: id.lowercased(), title: SessionTitleProjection.normalizedProviderTitle(text(value["title"])),
            workspaceURL: workspace, originWorkspaceURL: origin,
            worktreeName: origin == nil ? nil : (text(value["worktreeName"]) ?? workspace.lastPathComponent),
            branch: origin == nil ? nil : text(value["branch"]),
            model: text(value["model"]), effort: text(value["effort"]), permissionMode: text(value["permissionMode"]),
            isArchived: (value["isArchived"] as? Bool) == true, lastActivityAt: activity,
            desktopSessionID: desktopID,
            startedFromDesktopSessionID: (value["lineageDetached"] as? Bool) == true ? nil
                : text((value["spawnedFrom"] as? [String: Any])?["sessionId"]) ?? text(value["forkedFromSessionId"]),
            isCloud: isCloud,
            cloudURL: cloudURL)
    }

    /// Each session's parent by provider session ID (child `cliSessionId` → parent `cliSessionId`),
    /// for the sessions another session started and that still nest under it. The parent may be
    /// archived in the app; whether it is in Yardlet is the caller's question.
    static func parentSessionIDs(of sessions: [Session]) -> [String: String] {
        let cliByDesktop = Dictionary(
            sessions.compactMap { session in session.desktopSessionID.map { ($0, session.cliSessionID) } },
            uniquingKeysWith: { first, _ in first })
        var parents: [String: String] = [:]
        for session in sessions {
            guard let parent = session.startedFromDesktopSessionID.flatMap({ cliByDesktop[$0] }),
                  parent != session.cliSessionID else { continue }
            parents[session.cliSessionID] = parent
        }
        return parents
    }

    /// Every session file under `root` (`<organization>/<account>/local_*.json`). Links, other
    /// files and files that do not parse are skipped.
    static func sessions(in root: URL) -> [Session] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func entries(_ folder: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                              options: [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        var files: [URL] = []
        for organization in entries(root) where isFolder(organization) {
            for account in entries(organization) where isFolder(account) {
                for file in entries(account) where (file.lastPathComponent.hasPrefix("local_")
                    || file.lastPathComponent.hasPrefix("cloud_") || file.lastPathComponent.hasPrefix("remote_"))
                    && file.pathExtension == "json" {
                    guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                          values.isSymbolicLink != true, (values.fileSize ?? 0) <= maximumFileBytes else { continue }
                    files.append(file)
                    if files.count >= maximumFiles { break }
                }
            }
        }
        return files.compactMap { file in (try? Data(contentsOf: file)).flatMap(session(from:)) }
    }

    /// The session whose app ID (`local_…`) is `desktopSessionID`, from its own file under any
    /// organization and account: the one file is read, not the whole folder. Nil for anything that
    /// is not such an ID, so a link cannot name a path.
    static func session(desktopSessionID: String, in root: URL) -> Session? {
        guard desktopSessionID.wholeMatch(of: /(local|cloud|remote)_[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func folders(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                               options: [.skipsHiddenFiles])) ?? []).filter { folder in
                guard let values = try? folder.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        for organization in folders(root) {
            for account in folders(organization) {
                let file = account.appending(path: desktopSessionID + ".json")
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true, (values.fileSize ?? 0) <= maximumFileBytes,
                      let session = (try? Data(contentsOf: file)).flatMap(session(from:)) else { continue }
                return session
            }
        }
        return nil
    }

    /// The sessions the app has open (not archived) whose transcript is in this account's history,
    /// most recently active first, as conversations to import. A session listed twice (the app
    /// keeps a file per organization and account) is offered once.
    static func conversations(root: URL, configDirectory: URL) -> [ImportableConversation] {
        let running = ClaudeConversationCatalog.runningSessionIDs(configDirectory: configDirectory)
        var seen = Set<String>()
        let all = sessions(in: root)
        let parents = parentSessionIDs(of: all)
        return all
            .filter { !$0.isArchived }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .compactMap { session -> ImportableConversation? in
                guard seen.insert(session.cliSessionID).inserted else { return nil }
                return conversation(for: session, parents: parents, running: running, configDirectory: configDirectory)
            }
    }

    /// Every session whose transcript is in this account's history, open or archived in the app,
    /// for following the app's list (`SessionListFollow`). A session the app keeps under several
    /// organizations or accounts counts as open while any of its files is, and is listed once:
    /// from its most recently active open file, else its most recently active one.
    static func followedConversations(root: URL, configDirectory: URL) -> [SessionListFollow.Entry] {
        let running = ClaudeConversationCatalog.runningSessionIDs(configDirectory: configDirectory)
        var seen = Set<String>()
        let all = sessions(in: root)
        let parents = parentSessionIDs(of: all)
        return all
            .sorted { lhs, rhs in
                if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
                return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            }
            .compactMap { session -> SessionListFollow.Entry? in
                guard seen.insert(session.cliSessionID).inserted,
                      let conversation = conversation(for: session, parents: parents, running: running,
                                                      configDirectory: configDirectory) else { return nil }
                return SessionListFollow.Entry(conversation: conversation, isArchived: session.isArchived,
                                               sourceTitle: session.title)
            }
    }

    /// One session as a conversation to import, when its transcript is in this account's history
    /// and it has a title (the app's, else the transcript's).
    private static func conversation(
        for session: Session, parents: [String: String], running: Set<String>, configDirectory: URL
    ) -> ImportableConversation? {
        guard let transcript = ClaudeConversationCatalog.transcriptURL(
                  sessionID: session.cliSessionID, workspace: session.workspaceURL, configDirectory: configDirectory),
              let title = session.title ?? ClaudeConversationCatalog.title(of: transcript) else { return nil }
        let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        var conversation = ImportableConversation(
            harness: .claudeCode, providerSessionID: session.cliSessionID, title: title,
            workspaceURL: session.workspaceURL,
            updatedAt: session.lastActivityAt ?? modified ?? .distantPast,
            isOpenElsewhere: running.contains(session.cliSessionID))
        conversation.providerOptions = providerOptions(for: session)
        conversation.parentProviderSessionID = parents[session.cliSessionID]
        if let origin = session.originWorkspaceURL {
            conversation.workspaceOrigin = WorkspaceGitOrigin(
                originWorkspacePath: ProjectSidebarPresentation.normalizedPath(for: origin),
                worktreeName: session.worktreeName, branch: session.branch)
        }
        return conversation
    }

    /// The model, effort and permission mode the session ran with, under Yardlet's option keys.
    /// Claude's `default` permission mode is Yardlet's Manual; any other mode keeps its own name.
    static func providerOptions(for session: Session) -> [String: String] {
        var options: [String: String] = [:]
        if let model = session.model { options[ClaudeLaunchOption.model] = model }
        if let effort = session.effort { options[ClaudeLaunchOption.effort] = effort }
        if let mode = session.permissionMode {
            options[ClaudeLaunchOption.permissionMode] = mode == "default" ? ClaudePermissionMode.manual : mode
        }
        if session.isCloud { options["is_cloud"] = "true" }
        if let cloudURL = session.cloudURL { options["cloud_url"] = cloudURL }
        return options
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= 4_096 else { return nil }
        return text
    }
}
