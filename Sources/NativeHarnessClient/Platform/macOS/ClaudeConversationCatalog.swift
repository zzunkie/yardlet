import Darwin
import Foundation

/// A conversation another app left in a harness's own history, offered for import into Yardlet.
struct ImportableConversation: Identifiable, Equatable, Sendable {
    let harness: HarnessKind
    let providerSessionID: String
    let title: String
    let workspaceURL: URL
    let updatedAt: Date
    /// Another app's process still holds this conversation. It can be imported and read, and
    /// continues in Yardlet once that app lets it go.
    let isOpenElsewhere: Bool
    /// The text a search matched, when the list is a search's results.
    var snippet: String? = nil
    /// Where the other app ran it, when that was a worktree: the original repository, the
    /// worktree's name and branch. Git's own records win while the worktree is still there.
    var workspaceOrigin: WorkspaceGitOrigin? = nil
    /// The settings the other app ran it with, under Yardlet's own option keys.
    var providerOptions: [String: String] = [:]
    /// The provider session it was started from, when the other app records one (`TaskLineage`):
    /// a Claude app session another session started, a forked Codex thread.
    var parentProviderSessionID: String? = nil
    /// The remote or cloud URL for a cloud session.
    var cloudURL: URL? = nil
    var isCloud: Bool { cloudURL != nil || providerOptions["is_cloud"] == "true" }

    var id: String { harness.rawValue + ":" + providerSessionID }
}

extension ImportableConversation {
    /// A thread Codex keeps, named by its title, else its first request. Its last activity is
    /// when a person last worked in it, as the Codex app orders its list.
    init(codex thread: CodexThreadSummary, snippet: String? = nil) {
        self.init(harness: .codex, providerSessionID: thread.id,
                  title: thread.title.isEmpty
                      ? (thread.preview.isEmpty ? L10n.string("Imported Codex task") : thread.preview) : thread.title,
                  workspaceURL: thread.workspaceURL, updatedAt: thread.lastActivityAt, isOpenElsewhere: false,
                  snippet: snippet)
        parentProviderSessionID = TaskLineage.codexParentThreadID(forkedFromID: thread.forkedFromID, parentThreadID: nil)
        if thread.isCloud {
            providerOptions["is_cloud"] = "true"
            cloudURL = URL(string: "codex://threads/\(thread.id)")
        }
    }
}

/// One page of a folder's importable conversations, and where the next one starts.
struct ImportableConversationPage: Equatable, Sendable {
    var conversations: [ImportableConversation]
    var nextCursor: String? = nil

    /// This page followed by `next`, without a conversation the provider repeats across pages.
    func appending(_ next: ImportableConversationPage) -> ImportableConversationPage {
        var seen = Set(conversations.map(\.id))
        return ImportableConversationPage(conversations: conversations + next.conversations.filter { seen.insert($0.id).inserted },
                                          nextCursor: next.nextCursor)
    }
}

/// Lists Claude Code conversations for one folder from the config's `projects` folder, the way
/// Claude's own resume list finds them. Reads only the start and end of each transcript.
enum ClaudeConversationCatalog {
    /// Claude names a folder's history `projects/<path with every non-alphanumeric character as '-'>`.
    static func projectFolderName(for workspace: URL) -> String {
        // Claude replaces each UTF-16 unit of the composed path, so decomposed Hangul must not add dashes.
        let path = workspace.standardizedFileURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return String(trimmed.utf16.map { unit -> Character in
            switch unit {
            case 48...57, 65...90, 97...122: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        })
    }

    static func conversations(
        in workspace: URL,
        configDirectory: URL,
        limit: Int = 50
    ) -> [ImportableConversation] {
        let folder = configDirectory.appending(path: "projects", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
            .appending(path: projectFolderName(for: workspace), directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        let running = runningSessionIDs(configDirectory: configDirectory)
        let transcripts = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        return transcripts.compactMap { url, modified in
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let title = title(of: url) else { return nil }
            return ImportableConversation(harness: .claudeCode, providerSessionID: id, title: title,
                workspaceURL: workspace, updatedAt: modified, isOpenElsewhere: running.contains(id))
        }
    }

    /// The most recently active conversations of every folder in a config's history, for importing
    /// what Claude Code ran outside the Claude app (a terminal, another tool's account folder). Each
    /// one's folder is the `cwd` its transcript records, since a history folder's name cannot be
    /// turned back into a path. Only a transcript's start and end are read.
    static func recentConversations(configDirectory: URL, limit: Int = 200) -> [ImportableConversation] {
        let projects = configDirectory.appending(path: "projects", directoryHint: .isDirectory).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let transcripts = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []).compactMap { url -> (URL, Date)? in
                guard url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        let running = runningSessionIDs(configDirectory: configDirectory)
        return transcripts.compactMap { url, modified in
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let workspace = workingFolder(of: url), let title = title(of: url) else { return nil }
            return ImportableConversation(harness: .claudeCode, providerSessionID: id, title: title,
                workspaceURL: workspace, updatedAt: modified, isOpenElsewhere: running.contains(id))
        }
    }

    /// The folder a transcript's conversation ran in: the first `cwd` its records carry.
    static func workingFolder(of url: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 65_536)) ?? Data()
        let marker = Data(#""cwd":"#.utf8)
        for line in head.split(separator: 10) where line.range(of: marker) != nil {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let cwd = value["cwd"]?.stringValue, cwd.hasPrefix("/") else { continue }
            return URL(filePath: cwd, directoryHint: .isDirectory)
        }
        return nil
    }

    /// Claude Code registers each running process as `sessions/<pid>.json` with its session ID.
    /// A process this app started (its child or a child's child) is Yardlet's own, not another
    /// app's, and is left out, so a task Yardlet itself just stopped is not taken for one held
    /// elsewhere while its process exits.
    static func runningSessionIDs(configDirectory: URL, excludingProcessesOf owner: pid_t = getpid()) -> Set<String> {
        let folder = configDirectory.appending(path: "sessions", directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var result: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count < 65_536,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let pid = value["pid"]?.doubleValue, pid > 1, pid < Double(Int32.max),
                  let session = value["sessionId"]?.stringValue,
                  kill(pid_t(pid), 0) == 0 || errno == EPERM,
                  !isDescendant(pid_t(pid), of: owner) else { continue }
            result.insert(session.lowercased())
        }
        return result
    }

    /// Whether `owner` is among the process's ancestors (not the process itself).
    static func isDescendant(_ pid: pid_t, of owner: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent == owner { return true }
            guard parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    /// The conversation's transcript where Claude keeps the folder's history, when it is a regular
    /// file there. The config's `projects` may be a link to a folder another account shares.
    static func transcriptURL(sessionID: String, workspace: URL, configDirectory: URL) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let file = configDirectory.appending(path: "projects", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
            .appending(path: projectFolderName(for: workspace), directoryHint: .isDirectory)
            .appending(path: sessionID.lowercased() + ".jsonl")
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        return file
    }

    /// The name the person gave the conversation, otherwise the title Claude generated from it,
    /// otherwise its first request. A transcript with none of them (no exchange yet) is not offered.
    static func title(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 262_144
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(chunk) ? size - UInt64(chunk) : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        var generated: String?
        for line in tail.split(separator: 10).reversed() {
            guard line.count < 16_384,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            if value["type"]?.stringValue == "custom-title",
               let name = SessionTitleProjection.normalizedProviderTitle(value["customTitle"]?.stringValue) {
                return name
            }
            if generated == nil, value["type"]?.stringValue == "ai-title" {
                generated = SessionTitleProjection.normalizedProviderTitle(value["aiTitle"]?.stringValue)
            }
        }
        if let generated { return generated }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        // Claude writes its generated title soon after the first request, so a long transcript
        // can hold it only near the start.
        let marker = Data(#""type":"ai-title""#.utf8)
        for line in head.split(separator: 10).reversed() where line.range(of: marker) != nil {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let title = SessionTitleProjection.normalizedProviderTitle(value["aiTitle"]?.stringValue) else { continue }
            return title
        }
        for line in head.split(separator: 10) {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  value["type"]?.stringValue == "user", value["isMeta"]?.boolValue != true,
                  value["isSidechain"]?.boolValue != true,
                  !ClaudeSubagentTranscriptReader.isClaudesOwnNotice(value) else { continue }
            let content = value["message"]?["content"]
            let text = content?.stringValue ?? (content?.arrayValue ?? []).compactMap {
                $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
            }.joined(separator: " ")
            let trimmed = ClaudeHostNotice.stripped(text).trimmingCharacters(in: .whitespacesAndNewlines)
            // Slash commands, their output and interruption notes are not the request itself.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { continue }
            return String(trimmed.split(whereSeparator: \.isNewline).first ?? Substring(trimmed)).prefix(120)
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
