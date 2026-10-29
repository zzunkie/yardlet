import Foundation

extension CodexProtocol {
    static func compactConversation(id: Int64, threadID: String) -> CodexRPCRequest {
        .init(id: id, method: "thread/compact/start", params: .object(["threadId": .string(threadID)]))
    }

    static func collaborationModes(id: Int64) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "collaborationMode/list", params: .object([:]))
    }

    static func skills(id: Int64, workspaceURL: URL) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "skills/list",
            params: .object([
                "cwds": .array([.string(workspaceURL.standardizedFileURL.path)]),
                "forceReload": .bool(false)
            ])
        )
    }

    static func plugins(id: Int64, workspaceURL: URL) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "plugin/list",
            params: .object([
                "cwds": .array([.string(workspaceURL.standardizedFileURL.path)]),
                "forceRefetch": .bool(false)
            ])
        )
    }

    static func recentThreads(
        id: Int64,
        workspaceURL: URL,
        cursor: String? = nil,
        limit: Int64 = 30
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "archived": .bool(false),
            "cwd": .string(workspaceURL.standardizedFileURL.path),
            "limit": .integer(limit),
            "sortDirection": .string("desc"),
            "sortKey": .string("updated_at")
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return CodexRPCRequest(id: id, method: "thread/list", params: .object(params))
    }

    /// The source kinds of threads a person started: the CLI and TUI, the IDE extension and the
    /// Codex desktop app (both `vscode`), App Server clients, and cloud sessions. `exec` runs and subagent threads
    /// are the other kinds.
    static let interactiveSourceKinds = ["cli", "vscode", "appServer", "cloud"]

    /// Every folder's threads a person started, not archived (or, with `archived`, only the
    /// archived ones), the most recently updated first.
    static func interactiveThreads(
        id: Int64,
        cursor: String? = nil,
        limit: Int64 = 100,
        archived: Bool = false
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "archived": .bool(archived),
            "limit": .integer(limit),
            "sortDirection": .string("desc"),
            "sortKey": .string("updated_at"),
            "sourceKinds": .array(interactiveSourceKinds.map(JSONValue.string))
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return CodexRPCRequest(id: id, method: "thread/list", params: .object(params))
    }

    static func searchThreads(
        id: Int64,
        searchTerm: String,
        cursor: String? = nil,
        limit: Int64 = 30
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "archived": .bool(false),
            "limit": .integer(limit),
            "searchTerm": .string(searchTerm),
            "sortKey": .string("updated_at")
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return CodexRPCRequest(id: id, method: "thread/search", params: .object(params))
    }

    static func searchOccurrences(
        id: Int64,
        threadID: String,
        searchTerm: String,
        cursor: String? = nil,
        limit: Int64 = 30
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "searchTerm": .string(searchTerm),
            "limit": .integer(limit)
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return CodexRPCRequest(
            id: id,
            method: "thread/searchOccurrences",
            params: .object(params)
        )
    }

    static func setThreadName(
        id: Int64,
        threadID: String,
        name: String
    ) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/name/set",
            params: .object([
                "threadId": .string(threadID),
                "name": .string(name)
            ])
        )
    }

    static func archiveThread(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/archive",
            params: .object(["threadId": .string(threadID)])
        )
    }

    /// The commands a thread keeps running after its turns (experimental, App Server 0.163:
    /// `thread/backgroundTerminals/list`), one page.
    static func listBackgroundTerminals(id: Int64, threadID: String, cursor: String? = nil) -> CodexRPCRequest {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        if let cursor { params["cursor"] = .string(cursor) }
        return CodexRPCRequest(id: id, method: "thread/backgroundTerminals/list", params: .object(params))
    }

    /// Ends one of them (`thread/backgroundTerminals/terminate`).
    static func terminateBackgroundTerminal(id: Int64, threadID: String, processID: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/backgroundTerminals/terminate",
                        params: .object(["threadId": .string(threadID), "processId": .string(processID)]))
    }

    /// Ends all of them, as the Codex app's "Stop all background terminals" (`thread/backgroundTerminals/clean`).
    static func cleanBackgroundTerminals(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/backgroundTerminals/clean",
                        params: .object(["threadId": .string(threadID)]))
    }

    static func unarchiveThread(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/unarchive",
            params: .object(["threadId": .string(threadID)])
        )
    }

    static func deleteThread(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/delete",
            params: .object(["threadId": .string(threadID)])
        )
    }

    /// A fork is a new task, so `config` carries that task's own Yardlet MCP server rather than
    /// the source thread's.
    static func forkThread(
        id: Int64,
        threadID: String,
        workspaceURL: URL,
        config: JSONValue? = nil,
        throughTurnID: String? = nil,
        developerInstructions: String? = nil
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(workspaceURL.standardizedFileURL.path),
            "ephemeral": .bool(false),
            "excludeTurns": .bool(true)
        ]
        if let config { params["config"] = config }
        if let throughTurnID { params["lastTurnId"] = .string(throughTurnID) }
        if let developerInstructions { params["developerInstructions"] = .string(developerInstructions) }
        return CodexRPCRequest(id: id, method: "thread/fork", params: .object(params))
    }

    static func revertConversation(id: Int64, threadID: String, beforeTurnID: String) -> CodexRPCRequest {
        .init(id: id, method: "thread/revert", params: .object([
            "threadId": .string(threadID), "beforeTurnId": .string(beforeTurnID)
        ]))
    }

    static func reviewWorkingTree(id: Int64, threadID: String, target: CodexReviewTarget = .uncommittedChanges) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "review/start",
            params: .object([
                "threadId": .string(threadID),
                "delivery": .string("inline"),
                "target": target.jsonValue
            ])
        )
    }
}

struct CodexCapabilityProjector: Sendable {
    /// A preset without a mode is skipped, as the Codex app skips it. One without a model is kept:
    /// the installed App Server lists both of its presets with `model: null`.
    func modes(from result: JSONValue?) -> [CodexCollaborationPreset] {
        (result?["data"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue,
                  let mode = item["mode"]?.stringValue
            else { return nil }
            return CodexCollaborationPreset(
                name: name,
                mode: mode,
                model: item["model"]?.stringValue,
                reasoningEffort: item["reasoning_effort"]?.stringValue
            )
        }
    }

    func skills(from result: JSONValue?) -> [CodexSkillSummary] {
        let summaries = (result?["data"]?.arrayValue ?? []).flatMap { entry in
            (entry["skills"]?.arrayValue ?? []).compactMap { skill -> CodexSkillSummary? in
                guard let name = skill["name"]?.stringValue,
                      let path = skill["path"]?.stringValue
                else { return nil }
                let interface = skill["interface"]
                return CodexSkillSummary(
                    name: name,
                    displayName: interface?["displayName"]?.stringValue ?? name,
                    description: interface?["shortDescription"]?.stringValue
                        ?? skill["shortDescription"]?.stringValue
                        ?? skill["description"]?.stringValue
                        ?? "",
                    enabled: skill["enabled"]?.boolValue ?? false,
                    scope: skill["scope"]?.stringValue ?? "unknown",
                    path: path
                )
            }
        }
        return Dictionary(grouping: summaries, by: { $0.path })
            .compactMap { $0.value.first }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func plugins(from result: JSONValue?) -> [CodexPluginSummary] {
        let marketplaces = result?["marketplaces"]?.arrayValue ?? []
        var plugins: [CodexPluginSummary] = []
        for marketplace in marketplaces {
            let marketplaceName = marketplace["interface"]?["displayName"]?.stringValue
                ?? marketplace["name"]?.stringValue
                ?? "Codex"
            for plugin in marketplace["plugins"]?.arrayValue ?? [] {
                guard let id = plugin["id"]?.stringValue,
                      let name = plugin["name"]?.stringValue
                else { continue }
                let interface = plugin["interface"]
                plugins.append(CodexPluginSummary(
                    id: id,
                    name: name,
                    displayName: interface?["displayName"]?.stringValue ?? name,
                    description: interface?["shortDescription"]?.stringValue,
                    installed: plugin["installed"]?.boolValue ?? false,
                    enabled: plugin["enabled"]?.boolValue ?? false,
                    availability: plugin["availability"]?.stringValue ?? "AVAILABLE",
                    marketplace: marketplaceName
                ))
            }
        }
        return Dictionary(grouping: plugins, by: { $0.id })
            .compactMap { $0.value.first }
            .sorted {
                if $0.installed != $1.installed { return $0.installed && !$1.installed }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    func threads(from result: JSONValue?) -> [CodexThreadSummary] {
        recentThreadsPage(from: result).threads
    }

    func recentThreadsPage(from result: JSONValue?) -> CodexRecentThreadsPage {
        CodexRecentThreadsPage(
            threads: (result?["data"]?.arrayValue ?? []).compactMap(threadSummary(from:)),
            nextCursor: result?["nextCursor"]?.stringValue
        )
    }

    /// A `thread/list` page of threads a person started. The request already asks for those source
    /// kinds; a thread the answer still marks as an `exec` run, a subagent (a `subAgent` source or a
    /// parent thread) or ephemeral is left out here as well.
    func interactiveThreadsPage(from result: JSONValue?) -> CodexRecentThreadsPage {
        let threads = (result?["data"]?.arrayValue ?? []).filter { thread in
            let source = thread["source"]
            let kind = source?.stringValue ?? source.flatMap { value -> String? in
                guard case let .object(object) = value else { return nil }
                return object.keys.first
            }
            return kind != "exec" && kind != "subAgent"
                && (thread["parentThreadId"]?.stringValue ?? "").isEmpty
                && thread["ephemeral"]?.boolValue != true
        }
        return CodexRecentThreadsPage(threads: threads.compactMap(threadSummary(from:)),
                                      nextCursor: result?["nextCursor"]?.stringValue)
    }

    func searchPage(from result: JSONValue?) -> CodexThreadSearchPage {
        let matches = (result?["data"]?.arrayValue ?? []).compactMap { entry -> CodexThreadSearchMatch? in
            guard let thread = entry["thread"],
                  let summary = threadSummary(from: thread)
            else { return nil }
            return CodexThreadSearchMatch(
                thread: summary,
                snippet: entry["snippet"]?.stringValue
            )
        }
        return CodexThreadSearchPage(
            matches: matches,
            nextCursor: result?["nextCursor"]?.stringValue
        )
    }

    func searchOccurrencesPage(
        from result: JSONValue?
    ) -> CodexThreadSearchOccurrencesPage {
        let occurrences = (result?["data"]?.arrayValue ?? []).compactMap {
            occurrence -> CodexThreadSearchOccurrence? in
            guard let turnID = occurrence["turnId"]?.stringValue,
                  let itemID = occurrence["itemId"]?.stringValue,
                  let snippet = occurrence["snippet"]?.stringValue,
                  let turnCursor = occurrence["turnCursor"]?.stringValue,
                  let start = occurrence["snippetMatchRange"]?["start"]?.integerValue,
                  let end = occurrence["snippetMatchRange"]?["end"]?.integerValue,
                  start >= 0,
                  end >= start else {
                return nil
            }
            return CodexThreadSearchOccurrence(
                turnID: turnID,
                itemID: itemID,
                snippet: snippet,
                snippetMatchRange: CodexTextRange(
                    start: Int(start),
                    end: Int(end)
                ),
                turnCursor: turnCursor
            )
        }
        return CodexThreadSearchOccurrencesPage(
            occurrences: occurrences,
            nextCursor: result?["nextCursor"]?.stringValue
        )
    }

    private func threadSummary(from thread: JSONValue) -> CodexThreadSummary? {
        guard let id = thread["id"]?.stringValue,
              let cwd = thread["cwd"]?.stringValue,
              let updatedAt = thread["updatedAt"]?.integerValue
        else { return nil }
        // The preview is the first sent message as the Codex app wrote it; like the app, a title or
        // a list shows the person's request, not the context written before it (`CodexUserPrompt`).
        let sent = thread["preview"]?.stringValue ?? ""
        let preview = CodexUserPrompt.parse(sent, harness: .codex)?.request
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? sent
        let name = thread["name"]?.stringValue
        let title = (name?.isEmpty == false ? name : nil) ?? preview
        let source = thread["source"]
        let kind = source?.stringValue ?? source.flatMap { value -> String? in
            guard case let .object(object) = value else { return nil }
            return object.keys.first
        }
        let isCloud = kind == "cloud"
            || thread["isCloud"]?.boolValue == true
            || thread["environment"]?.stringValue?.lowercased() == "cloud"
        return CodexThreadSummary(
            id: id,
            title: title,
            preview: preview,
            workspaceURL: URL(filePath: cwd).standardizedFileURL,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
            forkedFromID: thread["forkedFromId"]?.stringValue,
            recencyAt: thread["recencyAt"]?.integerValue.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            isCloud: isCloud
        )
    }
}
