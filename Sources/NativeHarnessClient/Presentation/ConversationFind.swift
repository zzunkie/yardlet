import Foundation
import Observation

// Find in the open task's conversation (⌘F), after the Codex app's find-in-thread: the sent
// messages and the assistant's messages are searched — tool, command and reasoning cards are not —
// case-insensitively, one hit after another without overlap. Return and ⌘G go to the next match,
// Shift-Return and ⇧⌘G to the previous one, wrapping at either end. Going to a match inside folded
// work opens it, and the current match is scrolled into the middle of the conversation.

/// Where a match sits inside one searchable message. The keys follow the views that draw the
/// text, so a rendered text can tell which of the matches it holds.
enum ConversationFindSegmentKey: Hashable, Sendable {
    /// A sent message's whole text.
    case text
    /// A rendered Markdown block, by the path `TranscriptMarkdownBlocksView` gives it.
    case block([Int])
    /// A Markdown table cell; `row` is nil for the header.
    case cell([Int], row: Int?, column: Int)
}

struct ConversationFindSegment: Equatable, Sendable {
    let key: ConversationFindSegmentKey
    let text: String
}

/// The `occurrence`-th hit of the query in one segment.
struct ConversationFindLocation: Hashable, Sendable {
    let key: ConversationFindSegmentKey
    let occurrence: Int
}

struct ConversationFindMatch: Equatable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let unitID: String
        let location: ConversationFindLocation
    }

    let unitID: String
    /// The conversation row (Codex turn, transcript row) to bring into view first.
    let scrollID: String
    /// The folded work that has to open to show the match, if any.
    let revealID: String?
    let location: ConversationFindLocation

    var id: ID { ID(unitID: unitID, location: location) }
}

struct ConversationFindResult: Equatable, Sendable {
    let query: String
    let matches: [ConversationFindMatch]
    /// More matches exist than were kept.
    let isCapped: Bool

    static func empty(_ query: String) -> Self { Self(query: query, matches: [], isCapped: false) }
}

/// A message the find can reach.
struct ConversationFindUnit: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        /// Drawn as one plain text (a sent message).
        case plain(String)
        /// Drawn as Markdown (an assistant message); a Codex message also draws its directives.
        case markdown(String, dialect: TranscriptMarkdownDialect = .standard)
    }

    let id: String
    let scrollID: String
    let revealID: String?
    let body: Body
}

/// The conversation content a find reads, handed over by the view that shows it.
enum ConversationFindSource: Equatable, Sendable {
    /// The conversation model the renderer draws.
    case conversation(ConversationPresentation)

    /// The searchable messages in the order the conversation draws them.
    var units: [ConversationFindUnit] {
        switch self {
        case let .conversation(presentation):
            Self.conversationUnits(presentation)
        }
    }

    /// A turn's sent messages, then its work's messages in their order (the turn opens to show a match
    /// its fold hides, `ConversationTurn.workKeptWhenFolded`), then its answers. Every match scrolls to
    /// its turn.
    private static func conversationUnits(_ presentation: ConversationPresentation) -> [ConversationFindUnit] {
        var units: [ConversationFindUnit] = []
        // A Codex message draws its directives (`CodexMessageDirectives`); find reads what is drawn.
        let dialect = TranscriptMarkdownDialect(messagesOf: presentation.harness)
        for turn in presentation.turns {
            for item in turn.prompt where !item.isReadByQuestionCard {
                if let text = item.sentText, !text.isEmpty {
                    units.append(.init(id: item.id, scrollID: turn.id, revealID: nil, body: .plain(text)))
                }
            }
            let kept = Set(turn.workKeptWhenFolded.map(\.id))
            for item in turn.work {
                let revealID = kept.contains(item.id) ? nil : turn.id
                switch item.kind {
                case let .commentary(text, _), let .answer(text, _):
                    units.append(.init(id: item.id, scrollID: turn.id, revealID: revealID,
                                       body: .markdown(text, dialect: dialect)))
                case .userMessage where item.isReadByQuestionCard:
                    // The question card above draws it (`ConversationQuestionSummary`).
                    break
                case .userMessage, .scheduledTaskMessage:
                    if let text = item.sentText, !text.isEmpty {
                        units.append(.init(id: item.id, scrollID: turn.id, revealID: revealID, body: .plain(text)))
                    }
                default:
                    break
                }
            }
            for item in turn.answers {
                if case let .answer(text, _) = item.kind {
                    units.append(.init(id: item.id, scrollID: turn.id, revealID: nil, body: .markdown(text, dialect: dialect)))
                }
            }
        }
        return units
    }
}

/// Rendered texts kept from one search to the next, so only new or changed messages are parsed.
struct ConversationFindSegmentCache: Sendable {
    private struct Entry: Sendable {
        let body: ConversationFindUnit.Body
        let segments: [ConversationFindSegment]
    }

    private var entries: [String: Entry] = [:]

    var count: Int { entries.count }

    mutating func segments(for unit: ConversationFindUnit) -> [ConversationFindSegment] {
        if let entry = entries[unit.id], entry.body == unit.body { return entry.segments }
        let segments = ConversationFindEngine.segments(for: unit.body)
        entries[unit.id] = Entry(body: unit.body, segments: segments)
        return segments
    }

    mutating func retain(_ ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

enum ConversationFindEngine {
    /// Kept matches. The count reads "1,000+" past it, as the Codex app marks a capped count.
    static let matchLimit = 1_000

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive, non-overlapping hits, the way the Codex app counts them. Both the search and
    /// the rendered texts use this, so the count and the marks agree.
    static func occurrences(of query: String, in text: String, limit: Int = .max) -> [NSRange] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let string = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length, ranges.count < limit {
            let found = string.range(of: query, options: [.caseInsensitive],
                                     range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = NSMaxRange(found)
        }
        return ranges
    }

    static func segments(for body: ConversationFindUnit.Body) -> [ConversationFindSegment] {
        switch body {
        case let .plain(text): [ConversationFindSegment(key: .text, text: text)]
        case let .markdown(source, dialect): markdownSegments(source, dialect: dialect)
        }
    }

    /// The texts `TranscriptMarkdownText` draws, block by block. Code blocks count only the lines
    /// they show; list markers and dividers are not text.
    static func markdownSegments(_ source: String, dialect: TranscriptMarkdownDialect = .standard) -> [ConversationFindSegment] {
        var segments: [ConversationFindSegment] = []
        func visit(_ blocks: [TranscriptMarkdownBlock], path: [Int]) {
            for (index, block) in blocks.enumerated() {
                let path = path + [index]
                switch block {
                case let .paragraph(text), let .heading(_, text):
                    segments.append(.init(key: .block(path), text: text.plainText))
                case let .unorderedList(items, _), let .orderedList(_, items, _):
                    for (offset, item) in items.enumerated() { visit(item.blocks, path: path + [offset]) }
                case let .blockQuote(quoted):
                    visit(quoted, path: path)
                case let .code(_, text), let .mermaid(text):
                    // A diagram shows its source while find's current match is in it.
                    segments.append(.init(key: .block(path), text: TranscriptCodeWindow(text).text))
                case let .table(headers, rows, _):
                    for (column, header) in headers.enumerated() {
                        segments.append(.init(key: .cell(path, row: nil, column: column), text: header.plainText))
                    }
                    for (row, cells) in rows.enumerated() {
                        // The table draws as many columns as it has headers.
                        for (column, cell) in cells.prefix(headers.count).enumerated() {
                            segments.append(.init(key: .cell(path, row: row, column: column), text: cell.plainText))
                        }
                    }
                case .divider:
                    break
                case let .details(summary, _, inside):
                    // A disclosure's summary and the Markdown inside it, which a match opens.
                    segments.append(.init(key: .block(path), text: summary))
                    visit(inside, path: path)
                case .suggestedTask, .reviewComments, .visualization, .pictures:
                    // A card's labels and a picture's description are not the message's words.
                    break
                }
            }
        }
        visit(TranscriptMarkdownDocument(source, dialect: dialect).blocks, path: [])
        return segments
    }

    static func search(_ query: String, units: [ConversationFindUnit], cache: inout ConversationFindSegmentCache,
                       limit: Int = matchLimit) -> ConversationFindResult {
        guard !query.isEmpty else { return .empty(query) }
        var matches: [ConversationFindMatch] = []
        var isCapped = false
        units: for (index, unit) in units.enumerated() {
            if index % 64 == 0, Task.isCancelled { break }
            for segment in cache.segments(for: unit) {
                let hits = occurrences(of: query, in: segment.text, limit: limit - matches.count + 1)
                for occurrence in hits.indices {
                    guard matches.count < limit else {
                        isCapped = true
                        break units
                    }
                    matches.append(ConversationFindMatch(
                        unitID: unit.id, scrollID: unit.scrollID, revealID: unit.revealID,
                        location: ConversationFindLocation(key: segment.key, occurrence: occurrence)
                    ))
                }
            }
        }
        return ConversationFindResult(query: query, matches: matches, isCapped: isCapped)
    }

    /// Runs away from the main actor. Parsing is what costs: the cache keeps each message's texts.
    @concurrent
    static func search(_ query: String, in source: ConversationFindSource?, cache: ConversationFindSegmentCache,
                       limit: Int = matchLimit) async -> (result: ConversationFindResult, cache: ConversationFindSegmentCache) {
        var cache = cache
        let units = source?.units ?? []
        let result = search(query, units: units, cache: &cache, limit: limit)
        if !Task.isCancelled { cache.retain(Set(units.map(\.id))) }
        return (result, cache)
    }
}

/// What one message's texts mark. Each message reads only its own slot, so a new query or a move to
/// the next match redraws the messages it touches and leaves the rest of a long conversation alone.
@MainActor @Observable
final class ConversationFindSlot {
    enum Key: Hashable {
        case unit(String)
        case container(String)
    }

    /// The query this message marks, or nil when it holds no match.
    fileprivate(set) var query: String?
    /// The current match, when it is in this message.
    fileprivate(set) var active: ConversationFindLocation?
    /// Bumped each time the current match needs this folded container open.
    fileprivate(set) var revealToken = 0
}

struct ConversationFindScrollRequest: Equatable {
    let token: Int
    let scrollID: String
}

/// One task's find bar. It lives with the task's workspace state for the app session; nothing of it
/// is saved, and closing it clears the query as the Codex app does.
@MainActor @Observable
final class ConversationFindModel {
    enum SearchReason: Equatable {
        /// The query changed: keep the current position if it still exists, and show it.
        case typing
        /// Return with results from an older query: start from the first match.
        case submit
        /// The conversation changed underneath: keep the same match and do not scroll.
        case contentChanged
    }

    private(set) var isPresented = false
    var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    private(set) var result: ConversationFindResult?
    private(set) var activeIndex: Int?
    private(set) var isSearching = false
    /// Bumped each time the field should take keyboard focus.
    private(set) var focusRequest = 0
    private(set) var scrollRequest: ConversationFindScrollRequest?

    /// Typing and conversation updates wait this long; tests set it to zero.
    @ObservationIgnored var debounce: Duration = .milliseconds(150)
    @ObservationIgnored private var source: ConversationFindSource?
    @ObservationIgnored private var cache = ConversationFindSegmentCache()
    @ObservationIgnored private var slots: [ConversationFindSlot.Key: ConversationFindSlot] = [:]
    @ObservationIgnored private var markedUnits: Set<String> = []
    @ObservationIgnored private var activeUnit: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var contentChangedDuringSearch = false
    @ObservationIgnored private var scrollToken = 0
    @ObservationIgnored private var returnFocus: (@MainActor () -> Bool)?
    @ObservationIgnored private var centeredScrollToken: Int?

    var normalizedQuery: String { ConversationFindEngine.normalized(query) }

    var activeMatch: ConversationFindMatch? {
        guard let result, let activeIndex, result.matches.indices.contains(activeIndex) else { return nil }
        return result.matches[activeIndex]
    }

    /// The result for the query in the field, not one still on its way.
    var currentResult: ConversationFindResult? {
        guard let result, result.query == normalizedQuery else { return nil }
        return result
    }

    var hasMatches: Bool { !(result?.matches.isEmpty ?? true) }

    /// Opens the bar, or brings keyboard focus back to it. A single-line selection becomes the query,
    /// as ⌘F does in the Codex app.
    func open(selection: String? = nil, returnFocus: (@MainActor () -> Bool)? = nil) {
        if !isPresented {
            isPresented = true
            self.returnFocus = returnFocus
        }
        if let selection = selection.map(ConversationFindEngine.normalized), !selection.isEmpty,
           !selection.contains(where: \.isNewline) {
            query = selection
        }
        if !normalizedQuery.isEmpty, currentResult == nil, searchTask == nil { scheduleSearch(.typing) }
        focusRequest += 1
    }

    /// Closes the bar and clears the query and its marks. Returns whether keyboard focus went back to
    /// where it was when the bar opened.
    @discardableResult
    func close() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        query = ""
        cancelSearch()
        result = nil
        activeIndex = nil
        scrollRequest = nil
        source = nil
        cache = ConversationFindSegmentCache()
        updateMarks()
        for slot in slots.values where slot.revealToken != 0 { slot.revealToken = 0 }
        let restore = returnFocus
        returnFocus = nil
        return restore?() ?? false
    }

    func next() { move(by: 1) }

    func previous() { move(by: -1) }

    /// Return in the field: a result from an older query starts again at its first match.
    func submit(backward: Bool = false) {
        guard isPresented, !normalizedQuery.isEmpty else { return }
        guard currentResult != nil else {
            scheduleSearch(.submit, delay: .zero)
            return
        }
        move(by: backward ? -1 : 1)
    }

    /// The conversation the bar searches. Views hand it over only while the bar is open.
    func updateSource(_ source: ConversationFindSource) {
        let isFirst = self.source == nil
        self.source = source
        guard isPresented, !normalizedQuery.isEmpty else { return }
        scheduleSearch(isFirst || currentResult == nil ? .typing : .contentChanged)
    }

    /// Whether the drawn match should bring itself to the middle of the conversation for the scroll
    /// request `token`: true once per request, so a match drawn again later does not scroll back.
    /// A turn draws in a hosting view of its own (`ConversationTurnHost`), where the conversation's
    /// `ScrollViewReader` cannot reach the match, so the match scrolls the conversation itself.
    func claimCentering(_ token: Int) -> Bool {
        guard centeredScrollToken != token else { return false }
        centeredScrollToken = token
        return true
    }

    func slot(for key: ConversationFindSlot.Key) -> ConversationFindSlot {
        if let slot = slots[key] { return slot }
        let slot = ConversationFindSlot()
        slots[key] = slot
        return slot
    }

    /// Waits for the queued search, for tests.
    func waitForSearch() async {
        while let task = searchTask { await task.value }
    }

    // MARK: - Searching

    private func queryDidChange() {
        guard !normalizedQuery.isEmpty else {
            cancelSearch()
            result = nil
            activeIndex = nil
            updateMarks()
            return
        }
        guard isPresented else { return }
        isSearching = true
        scheduleSearch(.typing)
    }

    private func scheduleSearch(_ reason: SearchReason, delay: Duration? = nil) {
        // A queued search reads the newest conversation when it starts; one that is running
        // searches again once it is done.
        if reason == .contentChanged, searchTask != nil {
            contentChangedDuringSearch = true
            return
        }
        searchTask?.cancel()
        generation += 1
        let generation = generation
        let delay = delay ?? debounce
        // A conversation update searches quietly; only a new query shows progress.
        if reason != .contentChanged { isSearching = true }
        searchTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.runSearch(reason, generation: generation)
        }
    }

    private func runSearch(_ reason: SearchReason, generation: Int) async {
        guard generation == self.generation else { return }
        contentChangedDuringSearch = false
        let outcome = await ConversationFindEngine.search(normalizedQuery, in: source, cache: cache)
        guard !Task.isCancelled, generation == self.generation, isPresented else { return }
        cache = outcome.cache
        searchTask = nil
        isSearching = false
        apply(outcome.result, reason: reason)
        if contentChangedDuringSearch { scheduleSearch(.contentChanged) }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        contentChangedDuringSearch = false
        isSearching = false
    }

    private func apply(_ result: ConversationFindResult, reason: SearchReason) {
        let previous = activeMatch
        let previousIndex = activeIndex
        self.result = result
        let count = result.matches.count
        if count == 0 {
            activeIndex = nil
        } else {
            switch reason {
            case .typing:
                activeIndex = previousIndex.flatMap { $0 < count ? $0 : nil } ?? 0
            case .submit:
                activeIndex = 0
            case .contentChanged:
                activeIndex = previous.flatMap { match in result.matches.firstIndex { $0.id == match.id } }
                    ?? previousIndex.map { min($0, count - 1) } ?? 0
            }
        }
        updateMarks()
        if reason != .contentChanged { requestScroll() }
    }

    // MARK: - Moving

    private func move(by offset: Int) {
        guard isPresented, let result, !result.matches.isEmpty else { return }
        let count = result.matches.count
        let start = activeIndex ?? (offset > 0 ? -1 : 0)
        activeIndex = ((start + offset) % count + count) % count
        updateMarks()
        requestScroll()
    }

    private func requestScroll() {
        guard let match = activeMatch else { return }
        if let reveal = match.revealID { slot(for: .container(reveal)).revealToken += 1 }
        scrollToken += 1
        scrollRequest = ConversationFindScrollRequest(token: scrollToken, scrollID: match.scrollID)
    }

    /// Touches only the messages whose marks change.
    private func updateMarks() {
        let marked = result?.query
        let units = Set(result?.matches.map(\.unitID) ?? [])
        for id in markedUnits.subtracting(units) {
            let slot = slot(for: .unit(id))
            if slot.query != nil { slot.query = nil }
        }
        for id in units {
            let slot = slot(for: .unit(id))
            if slot.query != marked { slot.query = marked }
        }
        markedUnits = units

        let active = activeMatch
        if let previous = activeUnit, previous != active?.unitID {
            let slot = slot(for: .unit(previous))
            if slot.active != nil { slot.active = nil }
        }
        if let active {
            let slot = slot(for: .unit(active.unitID))
            if slot.active != active.location { slot.active = active.location }
        }
        activeUnit = active?.unitID
    }
}
