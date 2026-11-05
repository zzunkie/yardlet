import Foundation

enum SessionTitleProjection {
    static let maximumLength = 72

    static func provisionalTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init) ?? ""
        let normalized = collapsedWhitespace(firstLine)
        return normalized.isEmpty
            ? L10n.string("New task")
            : String(normalized.prefix(maximumLength))
    }

    static func normalizedProviderTitle(_ title: String?) -> String? {
        guard var title = title.map(collapsedWhitespace), !title.isEmpty else { return nil }
        title = removingBalancedQuotes(from: title)
        let lowercased = title.lowercased()
        let placeholders = ["new task", "new session", "untitled", "imported codex task"]
        guard !placeholders.contains(lowercased),
              !lowercased.hasPrefix("new task - "),
              !lowercased.hasPrefix("new session - ") else { return nil }
        return String(title.prefix(maximumLength))
    }

    /// Providers without title metadata still receive a stable, local title after the first turn.
    /// This is deliberately deterministic: title generation must not consume a hidden model turn.
    /// A chat's folder (`ChatWorkspaces`) is a generated name such as `new-chat-4` that says nothing
    /// about the task, so a chat's title is made from its request alone.
    static func fallbackTitle(firstUserMessage: String, workspaceURL: URL,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let provisional = provisionalTitle(from: firstUserMessage)
        let workspace = ChatWorkspaces.isChat(workspaceURL, home: home)
            ? "" : collapsedWhitespace(workspaceURL.lastPathComponent)
        let cleaned = cleanedRequest(provisional)

        if containsKoreanOperationQuestion(cleaned), !workspace.isEmpty {
            return String("\(workspace) \(koreanOperationCheck)".prefix(maximumLength))
        }
        if !cleaned.isEmpty, cleaned.caseInsensitiveCompare(provisional) != .orderedSame {
            return String(cleaned.prefix(maximumLength))
        }
        guard !workspace.isEmpty, provisional != L10n.string("New task") else {
            return provisional
        }
        return String("\(workspace) · \(provisional)".prefix(maximumLength))
    }

    /// The title a row shows under a project it already names. Only a title Yardlet made itself
    /// (`automatic` or `provisional`) loses the leading folder name `fallbackTitle` gives it; a
    /// provider's, the user's, or an older title shows as stored. The stored title is unchanged
    /// and keeps the project for the window title and anywhere else without the project row.
    static func titleUnderProject(_ session: SessionRecord, projectNames: [String]) -> String {
        guard session.titleOrigin == .automatic || session.titleOrigin == .provisional else {
            return session.title
        }
        var seen = Set<String>()
        let names = projectNames.map(collapsedWhitespace)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        for name in names {
            if let rest = removingLeadingName(name, from: session.title) { return rest }
        }
        return session.title
    }

    /// The title a task in the index reads with. A title Yardlet made for a chat (`automatic` or
    /// `provisional`) before `fallbackTitle` left a chat's folder out, `new-chat-4 · …`, reads
    /// without the folder's name, so the sidebar, the window title, the task tools and the remote
    /// windows all show it the way a new chat's title is made. Any other title reads as stored.
    static func storedTitle(_ title: String, origin: SessionTitleOrigin, workspaceURL: URL,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard origin == .automatic || origin == .provisional,
              let rest = removingLeadingName(collapsedWhitespace(workspaceURL.lastPathComponent), from: title),
              ChatWorkspaces.isChat(workspaceURL, home: home) else { return title }
        return rest
    }

    private static let koreanOperationCheck = "작동 상태 확인"

    /// `title` without the folder or project `name` that `fallbackTitle` put before it, or nil
    /// when the title does not start with it or nothing would be left.
    private static func removingLeadingName(_ name: String, from title: String) -> String? {
        guard !name.isEmpty else { return nil }
        if title.hasPrefix(name + " · ") {
            let rest = title.dropFirst(name.count + 3).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return title == "\(name) \(koreanOperationCheck)" ? koreanOperationCheck : nil
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func removingBalancedQuotes(from value: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return value }
        return collapsedWhitespace(String(value.dropFirst().dropLast()))
    }

    private static func cleanedRequest(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdownPrefixes = ["- ", "* ", "> ", "# ", "## ", "### "]
        for prefix in markdownPrefixes where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))

        let politePrefixes = [
            "could you ", "can you ", "would you ", "will you ", "please ",
            "could you please ", "can you please "
        ]
        let lowercased = cleaned.lowercased()
        if let prefix = politePrefixes.sorted(by: { $0.count > $1.count }).first(where: {
            lowercased.hasPrefix($0)
        }) {
            cleaned.removeFirst(prefix.count)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "?.! "))
        guard let first = cleaned.first else { return cleaned }
        return first.uppercased() + cleaned.dropFirst()
    }

    private static func containsKoreanOperationQuestion(_ value: String) -> Bool {
        let hasOperationWord = ["작동", "동작", "잘 돼", "잘되", "괜찮"].contains {
            value.localizedCaseInsensitiveContains($0)
        }
        let hasQuestionEnding = ["니", "나", "까", "어", "지", "?"]
            .contains { value.hasSuffix($0) }
        return hasOperationWord && hasQuestionEnding
    }
}
