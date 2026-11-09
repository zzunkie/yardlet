import Foundation

// A file's related tasks: the tasks that edited it or read it, shown where Yardlet shows a file (the
// review's file, the files panel), each opening its conversation where it touched the file
// (docs/NATIVE_SESSION_STORAGE.md, "Index of tasks that touched a file").

/// A file's related tasks, as the review and the files panel list them.
struct FileTasks: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let harness: HarnessKind
        /// When the task last edited the file, or, for a task that only read it, last read it.
        let at: Date
        /// The call its conversation shows that at.
        let callID: String
    }

    /// The tasks that edited the file, the latest edit first.
    var edited: [Item] = []
    /// The tasks that read it without editing it, the latest read first.
    var readOnly: [Item] = []

    var isEmpty: Bool { edited.isEmpty && readOnly.isEmpty }
}

/// A place in a task's conversation something outside it asked to show (`AppModel.revealCall`).
struct ConversationPlaceRequest: Equatable, Sendable {
    let id = UUID()
    /// The provider's ID of the call to show: a Claude Code `tool_use` ID, a Codex item ID, another
    /// harness's tool call ID.
    let callID: String
}

extension AppModel {
    /// The tasks Yardlet lists, archived ones aside, that edited or read `fileURL`. A Claude Code task's
    /// calls are read from its transcript, read on from where the last question left it; a Codex
    /// task's from the turns Yardlet has read of its thread, and any other task's from its conversation
    /// as Yardlet holds it, each kept for the next time (`FileTaskIndex`).
    func tasks(touching fileURL: URL) async -> FileTasks {
        guard let fileTaskIndex else { return FileTasks() }
        let sessions = store.sessions
        let candidates = sessions.map { session in
            FileTaskIndex.Candidate(
                id: session.id,
                folders: ([session.workspaceURL] + session.additionalRootURLs).map { $0.path(percentEncoded: false) },
                claude: session.harness == .claudeCode ? session.providerSessionID.map {
                    FileTaskIndex.ClaudeSource(reader: claudeSessionReader(for: session), sessionID: $0)
                } : nil,
                liveTouches: session.harness == .claudeCode ? [] : liveFileTouches(of: session)
            )
        }
        var knownWorktrees: [String: String] = [:]
        for session in sessions {
            guard let origin = session.originWorkspaceURL else { continue }
            knownWorktrees[FileRepositoryResolver.standardized(session.workspaceURL.path(percentEncoded: false))]
                = FileRepositoryResolver.standardized(origin.path(percentEncoded: false))
        }
        let matches = await fileTaskIndex.matches(for: fileURL.path(percentEncoded: false), among: candidates,
                                                  knownWorktrees: knownWorktrees)
        var tasks = FileTasks()
        for match in matches {
            guard let session = store.sessions.first(where: { $0.id == match.taskID }) else { continue }
            if let edit = match.marks.edit {
                tasks.edited.append(.init(id: session.id, title: session.title, harness: session.harness,
                                          at: edit.at, callID: edit.callID))
            } else if let read = match.marks.read {
                tasks.readOnly.append(.init(id: session.id, title: session.title, harness: session.harness,
                                            at: read.at, callID: read.callID))
            }
        }
        tasks.edited.sort { $0.at > $1.at }
        tasks.readOnly.sort { $0.at > $1.at }
        return tasks
    }

    /// What Yardlet holds in memory of a task's reads and edits: a Codex thread's applied file changes and
    /// the reads its commands were parsed into (`commandActions`), another harness's file changes its calls
    /// reported.
    private func liveFileTouches(of session: SessionRecord) -> [FileTouch] {
        if let thread = codexPresentationBySessionID[session.id]?.thread {
            return thread.turns.flatMap { turn in
                turn.items.flatMap { item -> [FileTouch] in
                    let at = item.completedAt ?? item.startedAt ?? turn.completedAt ?? turn.startedAt ?? Date()
                    switch item.content {
                    case let .fileChange(change)
                        where !["declined", "failed", "rejected"].contains(change.status.lowercased()):
                        return change.changes.compactMap { $0["path"]?.stringValue }.map {
                            FileTouch(path: Self.absolute($0, in: session.workspaceURL.path(percentEncoded: false)),
                                      kind: .edit, at: at, callID: item.id)
                        }
                    case let .commandExecution(command):
                        return command.actions.compactMap { action in
                            guard action["type"]?.stringValue == "read", let path = action["path"]?.stringValue else { return nil }
                            return FileTouch(path: Self.absolute(path, in: command.workspacePath), kind: .read,
                                             at: at, callID: item.id)
                        }
                    default:
                        return []
                    }
                }
            }
        }
        return (transcriptBySessionID[session.id] ?? []).compactMap { entry in
            guard case let .activity(activity, .completed) = entry.content, let path = activity.diff?.path,
                  activity.outcome == nil else { return nil }
            return FileTouch(path: Self.absolute(path, in: session.workspaceURL.path(percentEncoded: false)),
                             kind: .edit, at: entry.createdAt, callID: activity.id)
        }
    }

    private static func absolute(_ path: String, in folder: String) -> String {
        PathRules.current.isAbsolute(path) ? path : URL(filePath: folder, directoryHint: .isDirectory).appending(path: path)
            .path(percentEncoded: false)
    }

    /// Shows `callID`'s place in task `id`'s conversation: reads the task's saved conversation further
    /// back until it holds the call, as scrolling up reads it (a Claude Code transcript a step at a time,
    /// a Codex thread a page at a time), then asks the conversation to go to the turn holding it. Only
    /// reading: nothing is sent, attached or resumed.
    func revealCall(_ callID: String, in id: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        switch session.harness {
        case .claudeCode:
            if !isAttached(id), (transcriptBySessionID[id] ?? []).isEmpty {
                await refreshNativeClaudeConversation(for: session)
            }
            await readEarlier(until: { self.holdsCall(callID, in: id) }) {
                guard self.hasEarlierClaudeHistory(session) else { return false }
                await self.readEarlierClaudeHistory(for: session)
                return true
            }
        case .codex:
            if !isAttached(id), codexPresentationBySessionID[id]?.thread == nil {
                await readDetachedCodexThread(for: session)
            }
            await readEarlier(until: { self.holdsCall(callID, in: id) }) {
                guard self.codexPresentationBySessionID[id]?.thread?.turnsNextCursor?.isEmpty == false else { return false }
                await self.loadMoreCodexTurns(for: session)
                return true
            }
        default:
            break
        }
        guard store.sessions.contains(where: { $0.id == id }) else { return }
        conversationPlaceRequests[id] = ConversationPlaceRequest(callID: callID)
    }

    /// The conversation's place request was shown.
    func finishConversationPlace(_ request: ConversationPlaceRequest, in id: UUID) {
        if conversationPlaceRequests[id] == request { conversationPlaceRequests.removeValue(forKey: id) }
    }

    /// Reads further back, a step at a time, until `found` or `step` says there is nothing earlier. A
    /// step another read was already taking brings nothing; the next one waits a moment. Bounded, as a
    /// long transcript's start is a few dozen steps back.
    private func readEarlier(until found: () -> Bool, step: () async -> Bool) async {
        for _ in 0..<256 where !found() {
            let before = Date()
            guard await step() else { return }
            if Date().timeIntervalSince(before) < 0.01 { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    private func holdsCall(_ callID: String, in id: UUID) -> Bool {
        if let thread = codexPresentationBySessionID[id]?.thread,
           thread.turns.contains(where: { $0.items.contains { $0.id == callID } }) { return true }
        return (transcriptBySessionID[id] ?? []).contains { entry in
            if case let .activity(activity, _) = entry.content { return activity.id == callID }
            return false
        }
    }
}
