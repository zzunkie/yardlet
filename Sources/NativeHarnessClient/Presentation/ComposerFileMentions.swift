import Foundation
import Observation

/// An unfinished `@` word at the caret. Offsets are UTF-16, like the editor's selection.
struct ComposerMentionToken: Equatable, Sendable {
    let location: Int
    /// Includes the `@`.
    let length: Int
    let query: String
}

/// The native editor's selection together with the text it was measured in. The editor can
/// report a selection before the text binding catches up, so it applies only to that text.
struct ComposerCaret: Equatable, Sendable {
    let text: String
    let selection: NSRange
}

enum ComposerMentions {
    /// The token at the remembered caret, or at the end of the text when the caret belongs to a
    /// different text (a programmatic change). A selected range never opens the list.
    static func token(in text: String, caret: ComposerCaret?) -> ComposerMentionToken? {
        guard let caret, caret.text.utf16.elementsEqual(text.utf16) else { return token(in: text, caret: nil as Int?) }
        guard caret.selection.length == 0 else { return nil }
        return token(in: text, caret: caret.selection.location)
    }

    /// The `@word` the caret is in. The `@` must start a word, so an address such as
    /// `me@example.com` never opens the list; a caret before the `@` does not either.
    static func token(in text: String, caret: Int?) -> ComposerMentionToken? {
        let value = text as NSString
        let caret = min(max(caret ?? value.length, 0), value.length)
        var start = caret
        while start > 0, !isWhitespace(value.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < value.length, !isWhitespace(value.character(at: end)) { end += 1 }
        guard caret > start, value.character(at: start) == unichar(UInt8(ascii: "@")) else { return nil }
        let word = value.substring(with: NSRange(location: start, length: end - start))
        return ComposerMentionToken(location: start, length: end - start, query: String(word.dropFirst()))
    }

    /// Removes a chosen token, and the one space it leaves doubled, so the mention lives only in
    /// the attached context. Returns the caret where the token was, or nil when the text no
    /// longer holds that token (it changed while the list was open).
    static func removing(_ token: ComposerMentionToken, from text: String) -> (text: String, caret: Int)? {
        let value = text as NSString
        var start = token.location, end = token.location + token.length
        guard start >= 0, end <= value.length,
              value.substring(with: NSRange(location: start, length: token.length)) == "@" + token.query else { return nil }
        if end < value.length, value.character(at: end) == unichar(UInt8(ascii: " ")) {
            end += 1
        } else if start > 0, value.character(at: start - 1) == unichar(UInt8(ascii: " ")) {
            start -= 1
        }
        return (value.replacingCharacters(in: NSRange(location: start, length: end - start), with: ""), start)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// What the `@` list shows for one composer. A search replaces the previous one, so a slower
/// answer for an older query can never overwrite the current list.
@MainActor
@Observable
final class ComposerFileMentionSearch {
    private(set) var query: String?
    private(set) var matches: [WorkspaceFileMatch] = []
    private(set) var isSearching = false
    private(set) var failed = false
    private(set) var highlightedIndex = 0
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var roots: [URL] = []
    @ObservationIgnored private let index: WorkspaceFileSearchIndex

    init(index: WorkspaceFileSearchIndex = .shared) {
        self.index = index
    }

    var highlightedMatch: WorkspaceFileMatch? {
        matches.indices.contains(highlightedIndex) ? matches[highlightedIndex] : nil
    }

    func update(query: String?, roots: [URL],
                search externalSearch: (@MainActor (String) async -> WorkspaceFileSearchResult)? = nil) {
        guard query != self.query || roots != self.roots else { return }
        search?.cancel()
        self.query = query
        self.roots = roots
        failed = false
        guard let query, !query.isEmpty, externalSearch != nil || !roots.isEmpty else {
            matches = []
            highlightedIndex = 0
            isSearching = false
            return
        }
        isSearching = true
        let index = index
        search = Task { [weak self] in
            // Let a burst of keystrokes settle before ranking.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let result: WorkspaceFileSearchResult
            if let externalSearch { result = await externalSearch(query) }
            else { result = await index.search(query, in: roots) }
            guard !Task.isCancelled, let self, self.query == query else { return }
            matches = result.matches
            failed = result.failed
            highlightedIndex = 0
            isSearching = false
        }
    }

    func moveHighlight(by offset: Int) {
        guard !matches.isEmpty else { return }
        highlightedIndex = (highlightedIndex + offset + matches.count) % matches.count
    }

    func highlight(_ match: WorkspaceFileMatch) {
        if let index = matches.firstIndex(of: match) { highlightedIndex = index }
    }

    func reset() {
        update(query: nil, roots: [])
    }
}
