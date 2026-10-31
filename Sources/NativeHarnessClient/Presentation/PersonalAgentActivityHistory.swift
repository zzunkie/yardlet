import Foundation

/// The execution record of one task in a dot's Activity, read a page at a time and only to be read:
/// the thread's metadata, then its newest turns, then each turn's items, as the provider's own
/// Activity preview reads a task without resuming it. Turns and items are separate pages, so the
/// record is whole only once both run out (`isComplete`); a read that fails keeps what was read
/// and says which part is missing.
///
/// The thread's metadata never stands for its turns: the provider leaves them out of it, and the
/// turns come only from the turn pages.
struct PersonalAgentActivityHistory: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        /// The provider no longer has this task, or this account cannot see it.
        case missing
        case failed(PersonalAgentFailure)
    }

    /// The newest turns read when the task opens; earlier ones wait to be asked for.
    static let initialTurnCount = 5
    static let itemPageSize = 100
    /// The most of a page that is read; a larger page of items is asked for again in halves.
    static let maximumPageBytes = 8 * 1024 * 1024

    let threadID: String
    var phase: Phase = .loading
    /// The turns and items read so far, in the shape every Codex conversation is drawn from.
    var state = CodexTaskState.empty
    var isLoadingEarlierTurns = false
    var earlierTurnsFailure: PersonalAgentFailure?
    /// Turns whose items are being read.
    var loadingItems: Set<String> = []
    /// Turns whose last items read failed.
    var itemFailures: [String: PersonalAgentFailure] = [:]
    /// Turns none of whose items have been read yet.
    var unreadTurns: Set<String> = []
    private var turnCursors: Set<String> = []
    private var itemCursors: [String: Set<String>] = [:]

    init(threadID: String) { self.threadID = threadID }

    var turns: [CodexTurnState] { state.thread?.turns ?? [] }
    var hasEarlierTurns: Bool { state.thread?.turnsNextCursor != nil }
    /// The provider holds no turn for this task.
    var isEmpty: Bool { phase == .loaded && turns.isEmpty && !hasEarlierTurns }
    /// Some turn's items could not be read; the others show.
    var isPartial: Bool { !itemFailures.isEmpty }
    /// Every turn and every item the provider holds has been read.
    var isComplete: Bool {
        phase == .loaded && !hasEarlierTurns && unreadTurns.isEmpty && itemFailures.isEmpty
            && turns.allSatisfy { $0.itemsNextCursor == nil }
    }

    // MARK: Applying pages

    /// The thread as its metadata names it, with no turns yet.
    mutating func begin(_ thread: CodexThreadState) {
        var thread = thread
        thread.turns = []
        thread.turnsNextCursor = nil
        state = CodexTaskState(thread: thread)
        phase = .loaded
        turnCursors = []
        itemCursors = [:]
        unreadTurns = []
        itemFailures = [:]
        loadingItems = []
        earlierTurnsFailure = nil
    }

    /// A page of turns, oldest first: the newest page when `cursor` is nil, else the page before the
    /// turns read. Returns the turns it added, whose items are still to be read. A page that repeats
    /// a cursor, or names more turns to come without adding any, is not the provider's history.
    @discardableResult
    mutating func apply(turns page: CodexTurnPage, after cursor: String?) throws -> [String] {
        guard state.thread != nil else { throw PersonalAgentFailure.invalidResponse }
        if let next = page.nextCursor {
            if let cursor { turnCursors.insert(cursor) }
            guard next != cursor, !turnCursors.contains(next) else { throw PersonalAgentFailure.invalidResponse }
        }
        let known = Set(turns.map(\.id))
        let added = page.turns.filter { !known.contains($0.id) }
        if added.isEmpty, page.nextCursor != nil { throw PersonalAgentFailure.invalidResponse }
        CodexTaskReducer().mergeTurnPage(
            CodexTurnPage(turns: added, nextCursor: page.nextCursor, backwardsCursor: page.backwardsCursor),
            prepending: cursor != nil, into: &state
        )
        // A turn page names no items (`itemsView: notLoaded`): each turn's items are their own pages.
        for id in added.map(\.id) { setItemsCursor(nil, of: id) }
        unreadTurns.formUnion(added.map(\.id))
        return added.map(\.id)
    }

    /// A page of one turn's items, after `cursor` (nil for its first page).
    mutating func apply(items page: CodexItemPage, of turnID: String, after cursor: String?) throws {
        guard turns.contains(where: { $0.id == turnID }),
              page.entries.allSatisfy({ $0.turnID == turnID }) else { throw PersonalAgentFailure.invalidResponse }
        var seen = itemCursors[turnID] ?? []
        if let next = page.nextCursor {
            if let cursor { seen.insert(cursor) }
            guard next != cursor, !seen.contains(next), !page.entries.isEmpty else {
                throw PersonalAgentFailure.invalidResponse
            }
        }
        itemCursors[turnID] = seen
        CodexTaskReducer().mergeItemPage(
            CodexItemPage(entries: page.entries.map { .init(turnID: $0.turnID, item: Self.readOnly($0.item)) },
                          nextCursor: page.nextCursor, backwardsCursor: page.backwardsCursor),
            into: &state
        )
        setItemsCursor(page.nextCursor, of: turnID)
        unreadTurns.remove(turnID)
        itemFailures[turnID] = nil
    }

    /// The cursor to the turn's next items, and whether the ones read are all of them.
    private mutating func setItemsCursor(_ cursor: String?, of turnID: String) {
        guard let index = state.thread?.turns.firstIndex(where: { $0.id == turnID }) else { return }
        state.thread?.turns[index].itemsNextCursor = cursor
        state.thread?.turns[index].itemsView = cursor == nil ? .full : .summary
    }

    /// The next items of `turnID` to read: its first page while none is read, else its cursor.
    func itemsToRead(of turnID: String) -> (cursor: String?, more: Bool) {
        if unreadTurns.contains(turnID) { return (nil, true) }
        let cursor = turns.first { $0.id == turnID }?.itemsNextCursor
        return (cursor, cursor != nil)
    }

    // MARK: Reading the provider's pages

    /// The thread the metadata names, which must be the one asked for.
    static func thread(_ value: JSONValue, id: String) throws -> CodexThreadState {
        guard case var .object(fields)? = value["thread"], fields["id"]?.stringValue == id else {
            throw PersonalAgentFailure.invalidResponse
        }
        // The provider empties the metadata's turns on purpose; they never stand for the record.
        fields["turns"] = .array([])
        guard let thread = CodexTaskDecoder().thread(from: .object(fields)) else {
            throw PersonalAgentFailure.invalidResponse
        }
        return thread
    }

    /// A page of turns, asked newest first and returned oldest first, without items.
    static func turnPage(_ value: JSONValue) throws -> CodexTurnPage {
        guard case let .array(data)? = value["data"] else { throw PersonalAgentFailure.invalidResponse }
        var ids = Set<String>()
        let decoder = CodexTaskDecoder()
        let turns = try data.map { turn -> CodexTurnState in
            guard let id = turn["id"]?.stringValue, !id.isEmpty, ids.insert(id).inserted,
                  var decoded = decoder.turn(from: turn, fallbackID: id) else {
                throw PersonalAgentFailure.invalidResponse
            }
            // Asked without its items, a turn's items come only from its item pages, which are read
            // and checked as such; anything the turn carries is not taken for them.
            decoded.items = []
            return decoded
        }
        return CodexTurnPage(turns: turns.reversed(), nextCursor: try cursor(value["nextCursor"]),
                             backwardsCursor: try cursor(value["backwardsCursor"]))
    }

    /// A page of one turn's items. An entry wrapped with its turn must name that turn; a bare item,
    /// as some hosts send, is the turn's.
    static func itemPage(_ value: JSONValue, turnID: String) throws -> CodexItemPage {
        guard case let .array(data)? = value["data"] else { throw PersonalAgentFailure.invalidResponse }
        let decoder = CodexTaskDecoder()
        let entries = try data.map { entry -> CodexItemPageEntry in
            let item: JSONValue
            if let wrapped = entry["item"] {
                guard entry["turnId"]?.stringValue == turnID else { throw PersonalAgentFailure.invalidResponse }
                item = wrapped
            } else {
                item = entry
            }
            guard let id = item["id"]?.stringValue, !id.isEmpty else { throw PersonalAgentFailure.invalidResponse }
            return .init(turnID: turnID, item: decoder.item(from: item, fallbackID: id, lifecycle: .historical))
        }
        return CodexItemPage(entries: entries, nextCursor: try cursor(value["nextCursor"]),
                             backwardsCursor: try cursor(value["backwardsCursor"]))
    }

    /// A page's cursor, which the page must name: null at its end, else a string. A page without it
    /// says nothing about what follows, so it is not taken for the end.
    private static func cursor(_ value: JSONValue?) throws -> String? {
        switch value {
        case .null?: return nil
        case let .string(text)?: return text.isEmpty ? nil : text
        default: throw PersonalAgentFailure.invalidResponse
        }
    }

    /// Whether a link in the record opens: a web page does; a path or file names the provider's
    /// computer, not this Mac.
    static func opensLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A message part that would show a file: a local image, or an image whose address is not on the
    /// web or inline.
    private static func namesAFile(_ part: JSONValue) -> Bool {
        switch part["type"]?.stringValue {
        case "localImage": return true
        case "image":
            let scheme = part["url"]?.stringValue.flatMap(URL.init(string:))?.scheme?.lowercased() ?? ""
            return !["http", "https", "data"].contains(scheme)
        default: return false
        }
    }

    /// A cloud task names files on the provider's computer. Yardlet never reads the same path on this
    /// Mac, so an item that would show such a file says what it is instead of drawing it.
    static func readOnly(_ item: CodexItemState) -> CodexItemState {
        var item = item
        switch item.content {
        case .imageView:
            item.content = .unknown(type: "imageView", raw: item.raw)
        case let .imageGeneration(image) where image.savedPath != nil:
            item.content = image.result.isEmpty
                ? .unknown(type: "imageGeneration", raw: item.raw)
                : .imageGeneration(CodexImageGenerationItem(status: image.status, result: image.result,
                                                            revisedPrompt: image.revisedPrompt, savedPath: nil,
                                                            failure: image.failure))
        case let .userMessage(message) where message.content.contains(where: namesAFile):
            item.content = .unknown(type: "userMessage", raw: item.raw)
        default:
            break
        }
        return item
    }
}
