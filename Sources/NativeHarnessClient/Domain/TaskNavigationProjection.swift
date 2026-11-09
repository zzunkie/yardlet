import Foundation
import Observation

/// Pure task-index projection shared by the store and the SwiftUI sidebar. Keeping search and
/// grouping deterministic makes selection/restart fixtures independent of provider processes.
enum TaskNavigationProjection {
    /// Flattens the sidebar in its rendered order: globally pinned tasks first, followed by the
    /// remaining project-grouped tasks. A task appears exactly once in this sequence; projects with
    /// no unpinned tasks remain as empty sidebar groups but add no keyboard-navigation target.
    static func flattenedSessionIDs(in groups: [WorkspaceGroup]) -> [SessionRecord.ID] {
        pinnedSessions(in: groups).map(\.id)
            + unpinnedWorkspaceGroups(in: groups).flatMap { group in group.sessions.map(\.id) }
    }

    static func pinnedSessions(in groups: [WorkspaceGroup]) -> [SessionRecord] {
        groups
            .flatMap(\.sessions)
            .filter(\.isPinned)
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    static func unpinnedWorkspaceGroups(in groups: [WorkspaceGroup]) -> [WorkspaceGroup] {
        groups.map { group in
            WorkspaceGroup(
                workspaceURL: group.workspaceURL,
                sessions: group.sessions.filter { !$0.isPinned }
            )
        }
    }

    /// Returns the next visible task for keyboard navigation. A stale selection intentionally
    /// starts before the first item for Down and after the last item for Up, matching the command
    /// palette's deterministic wrap rule without inventing a task identity.
    static func targetSessionID(
        in groups: [WorkspaceGroup],
        selectedID: SessionRecord.ID?,
        offset: Int
    ) -> SessionRecord.ID? {
        let ids = flattenedSessionIDs(in: groups)
        guard !ids.isEmpty, offset != 0 else { return nil }
        let startingIndex = selectedID.flatMap { ids.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : ids.count)
        let targetIndex = (startingIndex + offset).modulo(ids.count)
        return ids[targetIndex]
    }

    static func workspaceGroups(from sessions: [SessionRecord]) -> [WorkspaceGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.workspaceURL.standardizedFileURL }
        return grouped
            .map { workspaceURL, sessions in
                WorkspaceGroup(
                    workspaceURL: workspaceURL,
                    sessions: sessions.sorted { lhs, rhs in
                        if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                )
            }
            .sorted { lhs, rhs in
                let lhsLatest = lhs.sessions.map(\.updatedAt).max() ?? .distantPast
                let rhsLatest = rhs.sessions.map(\.updatedAt).max() ?? .distantPast
                if lhsLatest == rhsLatest { return lhs.id.path < rhs.id.path }
                return lhsLatest > rhsLatest
            }
    }

    static func filteredGroups(
        from sessions: [SessionRecord],
        query: String,
        transcripts: [SessionRecord.ID: [TranscriptEntry]] = [:],
        codexPresentation: [SessionRecord.ID: CodexTaskState] = [:],
        projectNames: [URL: String] = [:]
    ) -> [WorkspaceGroup] {
        filteredGroups(
            in: workspaceGroups(from: sessions), query: query, transcripts: transcripts,
            codexPresentation: codexPresentation, projectNames: projectNames
        )
    }

    /// Search the visible registry as well as tasks, retaining matching empty projects.
    static func filteredGroups(
        in groups: [WorkspaceGroup],
        query: String,
        transcripts: [SessionRecord.ID: [TranscriptEntry]] = [:],
        codexPresentation: [SessionRecord.ID: CodexTaskState] = [:],
        projectNames: [URL: String] = [:]
    ) -> [WorkspaceGroup] {
        filteredGroups(in: groups, query: query, projectNames: projectNames,
                       conversationMatches: conversationMatches(transcripts: transcripts, codexPresentation: codexPresentation))
    }

    /// The groups with the tasks that match `query`; `conversationMatches` says whether a task's
    /// conversation holds the trimmed query.
    static func filteredGroups(
        in groups: [WorkspaceGroup],
        query: String,
        projectNames: [URL: String] = [:],
        conversationMatches: (SessionRecord.ID, String) -> Bool
    ) -> [WorkspaceGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        return groups.compactMap { group in
            if projectNames[group.workspaceURL]?.localizedCaseInsensitiveContains(trimmed) == true
                || group.workspaceURL.path(percentEncoded: false).localizedCaseInsensitiveContains(trimmed) {
                return group
            }
            let matches = filteredSessions(group.sessions, query: trimmed, conversationMatches: conversationMatches)
            guard !matches.isEmpty else { return nil }
            return WorkspaceGroup(workspaceURL: group.workspaceURL, sessions: matches)
        }
    }

    /// The tasks whose title, a name the person replaced, harness or conversation contains the
    /// query, as the groups' tasks are searched. The Chats section is searched this way; a chat's
    /// folder name is not.
    static func filteredSessions(
        _ sessions: [SessionRecord],
        query: String,
        transcripts: [SessionRecord.ID: [TranscriptEntry]] = [:],
        codexPresentation: [SessionRecord.ID: CodexTaskState] = [:]
    ) -> [SessionRecord] {
        filteredSessions(sessions, query: query,
                         conversationMatches: conversationMatches(transcripts: transcripts, codexPresentation: codexPresentation))
    }

    /// The tasks that match `query`; `conversationMatches` says whether a task's conversation holds
    /// the trimmed query, and is asked only of a task whose names do not.
    static func filteredSessions(
        _ sessions: [SessionRecord],
        query: String,
        conversationMatches: (SessionRecord.ID, String) -> Bool
    ) -> [SessionRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(trimmed)
                || session.previousTitles.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) })
                || session.harness.displayName.localizedCaseInsensitiveContains(trimmed)
                || conversationMatches(session.id, trimmed)
        }
    }

    private static func conversationMatches(
        transcripts: [SessionRecord.ID: [TranscriptEntry]],
        codexPresentation: [SessionRecord.ID: CodexTaskState]
    ) -> (SessionRecord.ID, String) -> Bool {
        { id, query in
            transcripts[id]?.contains(where: { transcriptEntry($0, contains: query) }) == true
                || codexPresentation[id].map { CodexHistorySearchProjection.contains(in: $0, query: query) } == true
        }
    }

    /// Whether `entry`'s text holds `query`, trimmed and not empty.
    fileprivate static func transcriptEntry(_ entry: TranscriptEntry, contains query: String) -> Bool {
        transcriptSearchText(for: entry).localizedCaseInsensitiveContains(query)
    }

    private static func transcriptSearchText(for entry: TranscriptEntry) -> String {
        switch entry.content {
        case let .user(text, images):
            ([ClaudeBashMessage.readableText(of: text) ?? text] + (images ?? []).compactMap(\.name)).joined(separator: "\n")
        case let .assistant(text, _), let .plan(text), let .reasoning(text, _):
            text
        case let .activity(activity, state):
            [
                activity.kind,
                activity.title,
                activity.detail ?? "",
                activity.input ?? "",
                activity.output ?? "",
                activity.diff?.path ?? "",
                state.rawValue
            ].joined(separator: " ")
        case let .permission(request, state):
            [request.title, request.detail ?? "", request.command ?? "", state.rawValue]
                .joined(separator: " ")
        case let .error(message, recoverable, _):
            "\(message) \(recoverable ? "recoverable" : "terminal")"
        case let .usageLimit(limit):
            limit.message ?? ""
        case .compaction:
            ""
        }
    }
}

/// Whether each task's conversation holds the sidebar search, for one window. The window reads these
/// answers and not the conversations: reading every task's conversation would make it observe them all
/// and draw again whenever any task streams. The model tells the memo whose conversation was set
/// (`AppModel.conversationSearch()`), and the memo searches that task again from what changed; the
/// window is told only when that changes whether the task matches.
///
/// A transcript is searched again from the first entry its change did not keep (`TranscriptChange`), and
/// a Codex thread from its first turn that is not the one searched. A task that matched still matches
/// while the entry or turn that matched stays as it was.
@MainActor
final class ConversationSearchMemo: Observable {
    /// A task's conversation as the model holds it, read without observing it.
    struct Conversation {
        var transcript: [TranscriptEntry]?
        var codex: CodexTaskState?

        init(transcript: [TranscriptEntry]? = nil, codex: CodexTaskState? = nil) {
            self.transcript = transcript
            self.codex = codex
        }
    }

    /// What was searched of a task, and where it matched: the entries or turns before a match, or all
    /// of them when none matched, do not hold the search.
    private struct Result {
        var entries: [TranscriptEntry] = []
        var entryMatch: Int?
        var turns: [CodexTurnState] = []
        var turnMatch: Int?
        var matches: Bool { entryMatch != nil || turnMatch != nil }
    }

    private let registrar = ObservationRegistrar()
    private let read: (SessionRecord.ID) -> Conversation
    private var query = ""
    private var results: [SessionRecord.ID: Result] = [:]
    /// Changes when a task searched comes to match or stops matching.
    private var answers = 0

    init(read: @escaping (SessionRecord.ID) -> Conversation) {
        self.read = read
    }

    /// Whether `id`'s conversation holds `query`, trimmed and not empty. The caller observes the answers,
    /// not the conversation.
    func matches(_ id: SessionRecord.ID, query: String) -> Bool {
        registrar.access(self, keyPath: \.answers)
        if query != self.query {
            self.query = query
            results.removeAll()
        }
        if let kept = results[id] { return kept.matches }
        let conversation = read(id)
        var result = Result()
        (result.entries, result.entryMatch) = search(conversation.transcript ?? [], after: nil, change: .unknown)
        (result.turns, result.turnMatch) = search(conversation.codex?.thread?.turns ?? [], after: nil)
        results[id] = result
        return result.matches
    }

    /// `id`'s transcript was set; `change` says what became of the entries searched.
    func transcriptChanged(_ id: SessionRecord.ID, change: TranscriptChange) {
        guard var result = results[id] else { return }
        let before = result.matches
        (result.entries, result.entryMatch) = search(read(id).transcript ?? [],
                                                     after: (result.entries, result.entryMatch), change: change)
        settle(result, for: id, matchedBefore: before)
    }

    /// `id`'s Codex state was set.
    func codexStateChanged(_ id: SessionRecord.ID) {
        guard var result = results[id] else { return }
        let before = result.matches
        (result.turns, result.turnMatch) = search(read(id).codex?.thread?.turns ?? [],
                                                  after: (result.turns, result.turnMatch))
        settle(result, for: id, matchedBefore: before)
    }

    /// Lets the conversations go once there is no search.
    func clear() {
        query = ""
        results.removeAll()
    }

    private func settle(_ result: Result, for id: SessionRecord.ID, matchedBefore: Bool) {
        results[id] = result
        guard result.matches != matchedBefore else { return }
        registrar.withMutation(of: self, keyPath: \.answers) { answers &+= 1 }
    }

    /// The first entry of `entries` that holds the search, from the first one `change` did not keep of
    /// the entries searched before.
    private func search(
        _ entries: [TranscriptEntry], after earlier: ([TranscriptEntry], Int?)?, change: TranscriptChange
    ) -> ([TranscriptEntry], Int?) {
        var start = 0
        if let (searched, match) = earlier {
            if let match, match - change.dropped >= 0, match - change.dropped < change.kept {
                return (entries, match - change.dropped)
            }
            start = max(0, min((match ?? searched.count) - change.dropped, change.kept, entries.count))
        }
        let query = query
        return (entries, entries[start...].firstIndex { TaskNavigationProjection.transcriptEntry($0, contains: query) })
    }

    /// The first turn of `turns` that holds the search, from the first one that is not as it was searched.
    private func search(_ turns: [CodexTurnState], after earlier: ([CodexTurnState], Int?)?) -> ([CodexTurnState], Int?) {
        var start = 0
        if let (searched, match) = earlier {
            if let match, match < turns.count, turns[match] == searched[match] { return (turns, match) }
            let clean = min(match ?? searched.count, turns.count)
            while start < clean, turns[start] == searched[start] { start += 1 }
        }
        let query = query
        return (turns, turns[start...].firstIndex { CodexHistorySearchProjection.contains(in: $0, trimmedQuery: query) })
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
