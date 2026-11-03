import Foundation

/// What one subscription of a phone holds of a conversation: whole turns from `startTurnID` to the
/// latest, and the items it last sent, so each update goes out as the changes since (§5.3).
///
/// - A page is whole turns counted back from the latest (or from before the window's start for
///   `loadOlder`), up to `limits`, at least one turn.
/// - An update compares the window's items with the ones sent: items whose relative order held are
///   replaced in place when they changed; the rest are removed and inserted where they now are. A
///   window whose first turn is gone, or a change too large to describe, is sent again whole
///   (`conversationReset`).
public struct RemoteConversationWindow: Sendable {
    public struct Limits: Sendable {
        public var maxTurns: Int
        public var maxItems: Int
        /// About how many bytes a page's items may take.
        public var maxBytes: Int
        /// More changes than this send the window again whole.
        public var maxChanges: Int

        public init(maxTurns: Int = 10, maxItems: Int = 120, maxBytes: Int = 384 * 1024, maxChanges: Int = 240) {
            self.maxTurns = maxTurns
            self.maxItems = maxItems
            self.maxBytes = maxBytes
            self.maxChanges = maxChanges
        }
    }

    public struct Page: Equatable, Sendable {
        public var items: [RemoteItem]
        public var cursor: String?
        public var hasOlder: Bool
    }

    public enum Update: Equatable, Sendable {
        case unchanged
        case changes([RemoteChange])
        case reset(Page)
    }

    public enum OlderResult: Equatable, Sendable {
        case page(Page)
        /// Every loaded turn is in the window and the provider holds earlier ones: ask it, then try again.
        case needsProvider
        case invalidCursor
    }

    public let limits: Limits
    public private(set) var startTurnID: String?
    public private(set) var sent: [RemoteItem] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// The cursor naming the window's start.
    public static func cursor(for turnID: String) -> String { "t:" + turnID }

    /// The latest page, which the window now holds.
    public mutating func open(_ conversation: RemoteConversation) -> Page {
        let start = pageStart(in: conversation.turns, before: conversation.turns.endIndex)
        startTurnID = conversation.turns.indices.contains(start) ? conversation.turns[start].id : nil
        sent = conversation.turns[start...].flatMap(\.items)
        return page(sent, start: start, conversation: conversation)
    }

    /// The turns just before the window's start, which the window then holds too.
    public mutating func older(_ cursor: String, in conversation: RemoteConversation) -> OlderResult {
        guard let startTurnID, cursor == Self.cursor(for: startTurnID),
              let current = conversation.turns.firstIndex(where: { $0.id == startTurnID }) else {
            return .invalidCursor
        }
        guard current > 0 else {
            if conversation.hasEarlier { return .needsProvider }
            return .page(Page(items: [], cursor: nil, hasOlder: false))
        }
        let start = pageStart(in: conversation.turns, before: current)
        let items = conversation.turns[start..<current].flatMap(\.items)
        self.startTurnID = conversation.turns[start].id
        sent = items + sent
        return .page(page(items, start: start, conversation: conversation))
    }

    /// What changed in the window since it was last sent.
    public mutating func update(_ conversation: RemoteConversation) -> Update {
        guard let startTurnID, let start = conversation.turns.firstIndex(where: { $0.id == startTurnID }) else {
            if startTurnID == nil, conversation.turns.isEmpty, sent.isEmpty { return .unchanged }
            return .reset(open(conversation))
        }
        let items = conversation.turns[start...].flatMap(\.items)
        guard let changes = Self.changes(from: sent, to: items) else { return .reset(open(conversation)) }
        guard changes.count <= limits.maxChanges else { return .reset(open(conversation)) }
        sent = items
        return changes.isEmpty ? .unchanged : .changes(changes)
    }

    // MARK: - Pages

    private func page(_ items: [RemoteItem], start: Int, conversation: RemoteConversation) -> Page {
        let hasOlder = start > 0 || conversation.hasEarlier
        let cursor = hasOlder && conversation.turns.indices.contains(start)
            ? Self.cursor(for: conversation.turns[start].id) : nil
        return Page(items: items, cursor: cursor, hasOlder: hasOlder && cursor != nil)
    }

    /// The first turn of the page that ends before `end`: whole turns back from `end` until a limit,
    /// at least one.
    private func pageStart(in turns: [RemoteTurn], before end: Int) -> Int {
        var start = end
        var items = 0
        var bytes = 0
        while start > turns.startIndex {
            let turn = turns[start - 1]
            let turnBytes = turn.items.reduce(0) { $0 + Self.estimatedBytes($1) }
            let taken = end - start
            if taken > 0, taken >= limits.maxTurns || items + turn.items.count > limits.maxItems
                || bytes + turnBytes > limits.maxBytes {
                break
            }
            start -= 1
            items += turn.items.count
            bytes += turnBytes
        }
        return start
    }

    /// About how many bytes an item takes in a page, as `Limits.maxBytes` counts them.
    public static func estimatedBytes(_ item: RemoteItem) -> Int {
        let texts = [item.text, item.title, item.detail, item.command, item.message, item.explanation]
        return 160 + texts.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            + (item.steps?.reduce(0) { $0 + $1.text.utf8.count + 40 } ?? 0)
            + (item.questions?.reduce(0) { $0 + $1.utf8.count } ?? 0)
    }

    // MARK: - Changes

    /// The changes that turn `old` into `new`, applied in order (§5.3): removals first, then each new
    /// or changed item after the one before it. Nil when either list repeats an ID.
    public static func changes(from old: [RemoteItem], to new: [RemoteItem]) -> [RemoteChange]? {
        var oldIndex: [String: Int] = [:]
        for (index, item) in old.enumerated() {
            guard oldIndex.updateValue(index, forKey: item.id) == nil else { return nil }
        }
        var newIDs = Set<String>()
        for item in new {
            guard newIDs.insert(item.id).inserted else { return nil }
        }
        // The items both hold, in the new order, by their old place; those in the longest run that
        // kept its order stay where they are.
        let common = new.compactMap { oldIndex[$0.id] }
        let kept = Set(longestIncreasingRun(common).map { old[$0].id })

        var changes: [RemoteChange] = []
        for item in old where !kept.contains(item.id) {
            changes.append(.remove(item.id))
        }
        var previous: String?
        for item in new {
            defer { previous = item.id }
            if kept.contains(item.id), let index = oldIndex[item.id], old[index] == item { continue }
            changes.append(.upsert(item, after: previous))
        }
        return changes
    }

    /// The values of the longest strictly increasing subsequence of `values`, in order.
    static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []  // indices into values
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(values[cursor])
            cursor = previous[cursor]
        }
        return run.reversed()
    }
}

extension Array where Element == RemoteItem {
    /// The items after applying a `conversation` event's changes, as a client applies them (§5.3).
    public func applying(_ changes: [RemoteChange]) -> [RemoteItem] {
        var items = self
        for change in changes {
            switch change.op {
            case .remove:
                items.removeAll { $0.id == change.id }
            case .upsert:
                guard let item = change.item else { continue }
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else if let after = change.after, let index = items.firstIndex(where: { $0.id == after }) {
                    items.insert(item, at: index + 1)
                } else {
                    items.insert(item, at: 0)
                }
            }
        }
        return items
    }
}
