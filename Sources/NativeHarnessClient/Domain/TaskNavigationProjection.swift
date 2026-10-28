import Foundation

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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        return groups.compactMap { group in
            if projectNames[group.workspaceURL]?.localizedCaseInsensitiveContains(trimmed) == true
                || group.workspaceURL.path(percentEncoded: false).localizedCaseInsensitiveContains(trimmed) {
                return group
            }
            let matches = filteredSessions(group.sessions, query: trimmed, transcripts: transcripts,
                                           codexPresentation: codexPresentation)
            guard !matches.isEmpty else { return nil }
            return WorkspaceGroup(workspaceURL: group.workspaceURL, sessions: matches)
        }
    }

    /// The tasks whose title, harness or conversation contains the query, as the groups' tasks
    /// are searched. The Chats section is searched this way; a chat's folder name is not.
    static func filteredSessions(
        _ sessions: [SessionRecord],
        query: String,
        transcripts: [SessionRecord.ID: [TranscriptEntry]] = [:],
        codexPresentation: [SessionRecord.ID: CodexTaskState] = [:]
    ) -> [SessionRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(trimmed)
                || session.harness.displayName.localizedCaseInsensitiveContains(trimmed)
                || transcripts[session.id]?.contains(where: { entry in
                    transcriptSearchText(for: entry).localizedCaseInsensitiveContains(trimmed)
                }) == true
                || codexPresentation[session.id].map {
                    CodexHistorySearchProjection.contains(in: $0, query: trimmed)
                } == true
        }
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

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
