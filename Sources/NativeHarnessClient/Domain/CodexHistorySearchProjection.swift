import Foundation

/// The provider returns a thread summary plus an optional matching snippet. This small
/// projection keeps the History sheet deterministic: matching is case-insensitive, preserves
/// the provider's original text, and never treats an empty query as a match.
struct CodexHistorySearchSegment: Equatable, Sendable {
    let text: String
    let isMatch: Bool
}

struct CodexHistorySearchSelection: Codable, Equatable, Sendable, Identifiable {
    let query: String
    let snippet: String?
    /// Provider identity is optional for backwards-compatible local fixture selections. When
    /// present, these fields let a hydrated timeline highlight the exact provider occurrence
    /// instead of guessing from local text.
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let turnCursor: String?
    let snippetMatchRange: CodexTextRange?

    init(
        query: String,
        snippet: String?,
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        turnCursor: String? = nil,
        snippetMatchRange: CodexTextRange? = nil
    ) {
        self.query = query
        self.snippet = snippet
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.turnCursor = turnCursor
        self.snippetMatchRange = snippetMatchRange
    }

    var id: String {
        [
            "query=\(query)",
            "snippet=\(snippet ?? String())",
            "thread=\(threadID ?? String())",
            "turn=\(turnID ?? String())",
            "item=\(itemID ?? String())",
            "cursor=\(turnCursor ?? String())"
        ].joined(separator: ";")
    }
}

struct CodexHistorySearchHit: Equatable, Sendable, Identifiable {
    let turnID: String
    let itemID: String

    var id: String { "\(turnID):\(itemID)" }
}

enum CodexHistorySearchProjection {
    /// Returns the next row of the import list for keyboard navigation, over the rows as listed
    /// (a row a provider repeated across pages counts once). Recent and search-backed rows share
    /// the same keyboard surface. A stale selection starts before the first row for Down and after
    /// the last row for Up, and wraps deterministically.
    static func targetID(
        in listedIDs: [String],
        selectedID: String?,
        offset: Int
    ) -> String? {
        var seen = Set<String>()
        let ids = listedIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, offset != 0 else { return nil }
        let startingIndex = selectedID.flatMap { ids.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : ids.count)
        let targetIndex = (startingIndex + offset).modulo(ids.count)
        return ids[targetIndex]
    }

    static func segments(_ text: String, query: String) -> [CodexHistorySearchSegment] {
        guard !text.isEmpty, !query.isEmpty else {
            return text.isEmpty ? [] : [CodexHistorySearchSegment(text: text, isMatch: false)]
        }

        var result: [CodexHistorySearchSegment] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let match = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<text.endIndex
              ) {
            if cursor < match.lowerBound {
                result.append(
                    CodexHistorySearchSegment(
                        text: String(text[cursor..<match.lowerBound]),
                        isMatch: false
                    )
                )
            }
            result.append(
                CodexHistorySearchSegment(
                    text: String(text[match]),
                    isMatch: true
                )
            )
            cursor = match.upperBound
        }

        if cursor < text.endIndex {
            result.append(
                CodexHistorySearchSegment(
                    text: String(text[cursor..<text.endIndex]),
                    isMatch: false
                )
            )
        }
        return result
    }

    static func accessibleSummary(
        title: String,
        snippet: String?,
        updatedLabel: String
    ) -> String {
        [title, snippet, updatedLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

    /// Finds hydrated provider items locally after an explicit History result is opened. The
    /// provider's `thread/search` response does not expose a stable turn/item match ID, so the
    /// projection searches only already-hydrated typed content and never invents a wire request.
    static func hits(in state: CodexTaskState, query: String) -> [CodexHistorySearchHit] {
        state.thread?.turns.flatMap { hits(in: $0, query: query) } ?? []
    }

    /// One turn's part of `hits(in:query:)`.
    static func hits(in turn: CodexTurnState, query: String) -> [CodexHistorySearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return turn.items.compactMap { item in
            guard searchableText(for: item).localizedCaseInsensitiveContains(trimmed) else {
                return nil
            }
            return CodexHistorySearchHit(turnID: turn.id, itemID: item.id)
        }
    }

    /// Sidebar filtering needs only one match from already-loaded history, not a full hit list.
    static func contains(in state: CodexTaskState, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let thread = state.thread else { return false }
        return thread.turns.contains { contains(in: $0, trimmedQuery: trimmed) }
    }

    /// One turn's part of `contains(in:query:)`, for a query already trimmed and not empty.
    static func contains(in turn: CodexTurnState, trimmedQuery: String) -> Bool {
        turn.items.contains { searchableText(for: $0).localizedCaseInsensitiveContains(trimmedQuery) }
    }

    static func matchingTurnIDs(in state: CodexTaskState, query: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for hit in hits(in: state, query: query) where seen.insert(hit.turnID).inserted {
            result.append(hit.turnID)
        }
        return result
    }

    static func hits(
        in state: CodexTaskState,
        selection: CodexHistorySearchSelection
    ) -> [CodexHistorySearchHit] {
        if let turnID = selection.turnID,
           let itemID = selection.itemID,
           state.thread?.turns.contains(where: { turn in
               turn.id == turnID && turn.items.contains(where: { $0.id == itemID })
           }) == true {
            return [CodexHistorySearchHit(turnID: turnID, itemID: itemID)]
        }
        return hits(in: state, query: selection.query)
    }

    private static func searchableText(for item: CodexItemState) -> String {
        switch item.content {
        case let .userMessage(message):
            // Current requests use typed input objects; older snapshots may contain strings.
            return ([message.displayText] + message.content.compactMap(\.stringValue))
                .joined(separator: "\n")
        case let .agentMessage(message):
            return message.text
        case let .plan(text):
            return text
        case let .reasoning(summary, content):
            return (summary + content).compactMap(\.stringValue).joined(separator: " ")
        case let .commandExecution(command):
            return [command.command, command.aggregatedOutput].compactMap { $0 }.joined(separator: " ")
        case let .fileChange(change):
            // File-change entries are JSON objects rather than scalar strings. Keep the
            // provider's path/kind/line metadata searchable for the local fallback instead of
            // silently dropping every change from History search.
            return change.changes.map(searchableJSONValue).joined(separator: " ")
        case let .mcpToolCall(tool):
            return [tool.server, tool.tool, tool.error.map(searchableJSONValue), tool.result.map(searchableJSONValue)]
                .compactMap { $0 }
                .joined(separator: " ")
        case let .dynamicToolCall(tool):
            return [tool.namespace, tool.tool].compactMap { $0 }.joined(separator: " ")
        case let .collaboration(collaboration):
            return [
                collaboration.tool,
                collaboration.senderThreadID,
                collaboration.receiverThreadIDs.joined(separator: " "),
                collaboration.prompt,
                collaboration.model,
                collaboration.reasoningEffort
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        case let .subagentActivity(activity):
            return [activity.agentThreadID, activity.agentPath, activity.kind].joined(separator: " ")
        case let .webSearch(query, _, _):
            return query
        case let .imageView(path):
            return path
        case let .sleep(durationMilliseconds):
            return String(durationMilliseconds)
        case let .imageGeneration(image):
            return [image.status, image.result, image.revisedPrompt, image.savedPath]
                .compactMap { $0 }
                .joined(separator: " ")
        case let .enteredReviewMode(review), let .exitedReviewMode(review):
            return review
        case let .notice(notice):
            return [notice.message, notice.details].compactMap { $0 }.joined(separator: " ")
        case let .unknown(type, raw):
            return [type, searchableJSONValue(raw)].compactMap { $0 }.joined(separator: " ")
        case .hookPrompt, .contextCompaction:
            return item.content.typeName
        }
    }

    private static func searchableJSONValue(_ value: JSONValue) -> String {
        switch value {
        case let .string(string):
            return string
        case let .integer(integer):
            return String(integer)
        case let .number(number):
            return String(number)
        case let .bool(boolean):
            return boolean ? "true" : "false"
        case let .array(values):
            return values.map(searchableJSONValue).joined(separator: " ")
        case let .object(object):
            return object
                .sorted { $0.key < $1.key }
                .flatMap { key, value in [key, searchableJSONValue(value)] }
                .joined(separator: " ")
        case .null:
            return ""
        }
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
