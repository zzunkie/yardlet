import Foundation
import YardletRemote

extension RemoteHostModel {
    func readComposerState(_ taskID: String) async -> RemoteComposerState? {
        guard isConnected, composerExtensions else { return nil }
        let reply = await response(to: .composerState(taskID: taskID))
        if reply.ok, let state = reply.composerState { composerStates[taskID] = state }
        return reply.ok ? reply.composerState : nil
    }

    func actOnComposer(_ taskID: String, action: String, itemID: String? = nil,
                       value: String? = nil) async -> RemoteComposerState? {
        let reply = await response(to: .composerAction(taskID: taskID, action: action, itemID: itemID, value: value))
        guard reply.ok else {
            commandError = Self.message(for: reply.error, host: name)
            return nil
        }
        commandError = nil
        if let state = reply.composerState { composerStates[taskID] = state }
        return reply.composerState
    }
}

/// A bounded host listing is shared by successive queries. Only ranking happens per keystroke;
/// host paths are values and are never opened on this Mac.
@MainActor
final class RemoteComposerMentionIndex {
    private var key: String?
    private var loadedAt: ContinuousClock.Instant?
    private var listing: Task<(URL, [WorkspaceFileRanking.Entry])?, Never>?

    func search(_ query: String, model: RemoteHostModel, taskID: String) async -> WorkspaceFileSearchResult {
        await search(query, key: taskID) { await model.response(to: .workspaceFiles(taskID: taskID)) }
    }

    func search(_ query: String, key: String,
                load: @escaping @MainActor () async -> RemoteResponse) async -> WorkspaceFileSearchResult {
        if self.key != key || loadedAt.map({ ContinuousClock.now - $0 >= .seconds(15) }) == true {
            listing = nil
            self.key = key
        }
        if listing == nil {
            loadedAt = .now
            listing = Task {
                let response = await load()
                guard response.ok, let paths = response.filePaths,
                      let path = response.workspaceRoot, path.hasPrefix("/") else { return nil }
                let root = URL(filePath: path)
                let safePaths = paths.filter {
                    !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains { $0 == ".." || $0 == "." }
                }
                let entries = await Task.detached(priority: .userInitiated) {
                    WorkspaceFileRanking.entries(forFiles: safePaths)
                }.value
                return (root, entries)
            }
        }
        guard let (root, entries) = await listing?.value else { return .init(failed: true) }
        return await Task.detached(priority: .userInitiated) {
            .init(matches: WorkspaceFileRanking.rank(entries, query: query, limit: 50).map {
                WorkspaceFileMatch(root: root, relativePath: $0.relativePath, isDirectory: $0.isDirectory)
            })
        }.value
    }

    /// Chips retain the host identity separately from files attached on this Mac.
    static func insert(_ match: WorkspaceFileMatch, replacing token: ComposerMentionToken,
                       into draft: some ComposerDraftEditing) -> ComposerMentionEdit? {
        guard let edit = ComposerMentions.removing(token, from: draft.text) else { return nil }
        draft.text = edit.text
        if !draft.hostMentions.contains(match) { draft.hostMentions.append(match) }
        return ComposerMentionEdit(caret: edit.caret)
    }

    /// The ordinary host text path accepts quoted references without resolving client URLs. They are relative to
    /// the task's folder, so no host path lands in this Mac's drafts and a task in a new worktree reads its own copy.
    static func message(_ text: String, mentions: [WorkspaceFileMatch]) -> String {
        let references = mentions.map { match in
            let path = match.isDirectory && !match.relativePath.hasSuffix("/") ? match.relativePath + "/" : match.relativePath
            return "@\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n")
    }

}

extension RemoteComposerState {
    var connectorList: ComposerConnectorList? {
        guard let connectors else { return nil }
        return ComposerConnectorList(rows: connectors.map { row in
            let state: ComposerConnectorList.Row.State = switch row.state {
            case "connected": .connected
            case "pending": .pending
            case "needsAuthentication": .needsAuthentication
            case "disabled": .disabled
            case "notConnected": .notConnected
            case "offInTask": .offInTask
            case "harnessHasIt": .harnessHasIt
            case "yardletStandsIn": .yardletStandsIn
            default: .failed
            }
            return .init(id: row.id, name: row.name, state: state, toolCount: row.toolCount,
                         source: row.source == "yardlet" ? .yardlet : .session,
                         connectorID: row.connectorID.flatMap(UUID.init(uuidString:)), presetID: row.presetID)
        }, toolListFollowsNextTurn: toolListFollowsNextTurn)
    }
}

