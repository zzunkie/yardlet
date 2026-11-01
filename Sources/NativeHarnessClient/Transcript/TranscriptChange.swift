import Foundation

/// What became of a transcript's entries since an earlier state of them: the first `dropped` entries
/// went, and the first `kept` entries now are the entries that followed them then, unchanged. What
/// comes after those may have changed in any way. A conversation keeps the turns of its transcript
/// that a change left as they were (`TranscriptTurns.updated(to:change:)`) without comparing them.
struct TranscriptChange: Equatable, Sendable {
    var dropped: Int
    var kept: Int

    /// Nothing is known to have stayed the same.
    static let unknown = TranscriptChange(dropped: 0, kept: 0)

    /// Nothing changed in `count` entries.
    static func none(_ count: Int) -> TranscriptChange { TranscriptChange(dropped: 0, kept: count) }

    /// This change, then `later`.
    func then(_ later: TranscriptChange) -> TranscriptChange {
        TranscriptChange(dropped: dropped + later.dropped, kept: min(later.kept, max(kept - later.dropped, 0)))
    }
}

/// A transcript's entries that note what changed since the change was last taken
/// (`takeChange()`). Every change to a collection goes through its two mutations, setting an element
/// and replacing a range, so whatever changes the entries is noted, however it changes them.
struct TranscriptEntryList: RandomAccessCollection, MutableCollection, RangeReplaceableCollection, Sendable {
    private(set) var elements: [TranscriptEntry]
    private var change: TranscriptChange

    init() {
        elements = []
        change = .unknown
    }

    /// Entries of which nothing is known: the first change taken says so.
    init(_ elements: [TranscriptEntry]) {
        self.elements = elements
        change = .unknown
    }

    var startIndex: Int { elements.startIndex }
    var endIndex: Int { elements.endIndex }

    subscript(position: Int) -> TranscriptEntry {
        get { elements[position] }
        set {
            elements[position] = newValue
            change.kept = Swift.min(change.kept, position)
        }
    }

    mutating func replaceSubrange<C: Collection>(_ subrange: Range<Int>, with newElements: C)
        where C.Element == TranscriptEntry {
        elements.replaceSubrange(subrange, with: newElements)
        if subrange.lowerBound == 0, newElements.isEmpty {
            // The oldest entries went; the rest moved up as they were.
            change = change.then(TranscriptChange(dropped: subrange.count, kept: elements.count))
        } else {
            change.kept = Swift.min(change.kept, subrange.lowerBound)
        }
    }

    /// What changed since the change was last taken, or since the entries were given.
    mutating func takeChange() -> TranscriptChange {
        defer { change = .none(elements.count) }
        return change
    }
}
