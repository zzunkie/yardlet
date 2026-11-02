import Foundation
import YardletRemote

/// The items a client holds of one subscribed conversation (docs/REMOTE_PROTOCOL.md §5.3), kept in runs of
/// one turn each, so that a change costs what it touches: replacing a streaming answer finds its run by the
/// item's ID, and inserting reads only its run. The runs keep the host's order exactly; a change whose
/// `after` names an item not held reports the conversation out of step, never guessing a place.
struct RemoteConversationItems {
    /// One turn's items, in order. A class, so an item's run is found from its ID without an index that
    /// every insertion would shift.
    final class Run {
        let turnID: String
        var items: [RemoteItem]
        /// Bumped whenever the run changes, which tells its projection to draw it again.
        var version = 0

        init(turnID: String, items: [RemoteItem]) {
            self.turnID = turnID
            self.items = items
        }
    }

    private(set) var runs: [Run] = []
    private var runOf: [String: Run] = [:]

    var isEmpty: Bool { runs.isEmpty }

    /// The run an item is in.
    func run(containing itemID: String) -> Run? { runOf[itemID] }
    var count: Int { runs.reduce(0) { $0 + $1.items.count } }
    var items: [RemoteItem] { runs.flatMap(\.items) }

    init(_ items: [RemoteItem] = []) {
        replace(with: items)
    }

    /// A fresh page (`subscribeTask`, `conversationReset`).
    mutating func replace(with items: [RemoteItem]) {
        runs = Self.runs(of: items)
        runOf = [:]
        for run in runs { for item in run.items { runOf[item.id] = run } }
    }

    /// A `loadOlder` page, before everything held.
    mutating func prepend(_ items: [RemoteItem]) {
        var added = Self.runs(of: items)
        guard !added.isEmpty else { return }
        for run in added { for item in run.items { runOf[item.id] = run } }
        if let last = added.last, let first = runs.first, last.turnID == first.turnID {
            first.items.insert(contentsOf: last.items, at: 0)
            first.version += 1
            for item in last.items { runOf[item.id] = first }
            added.removeLast()
        }
        runs.insert(contentsOf: added, at: 0)
    }

    /// Applies a `conversation` event's changes in order. False when a change named an item not held: the
    /// client is out of step and subscribes again (§5.3). A run it changed has a new `version`.
    mutating func apply(_ changes: [RemoteChange]) -> Bool {
        var reshaped = false
        for change in changes {
            switch change.op {
            case .remove:
                guard let id = change.id, let run = runOf.removeValue(forKey: id),
                      let index = run.items.firstIndex(where: { $0.id == id }) else { continue }
                run.items.remove(at: index)
                run.version += 1
                if run.items.isEmpty {
                    runs.removeAll { $0 === run }
                }
                reshaped = true
            case .upsert:
                guard let item = change.item else { continue }
                if let run = runOf[item.id], let index = run.items.firstIndex(where: { $0.id == item.id }) {
                    if run.turnID == item.turnId {
                        run.items[index] = item
                        run.version += 1
                        continue
                    }
                    // In place, under another turn: taken out here and put back where it was.
                    let before = index > 0 ? run.items[index - 1].id : previousID(before: run)
                    run.items.remove(at: index)
                    run.version += 1
                    runOf[item.id] = nil
                    if run.items.isEmpty {
                        runs.removeAll { $0 === run }
                    }
                    reshaped = true
                    guard insert(item, after: before) else { return false }
                } else {
                    guard insert(item, after: change.after) else { return false }
                }
            }
        }
        if reshaped { mergeNeighbors() }
        return true
    }

    /// The item before a run's first: the last item of the run before it.
    private func previousID(before run: Run) -> String? {
        guard let index = runs.firstIndex(where: { $0 === run }), index > 0 else { return nil }
        return runs[index - 1].items.last?.id
    }

    /// Puts `item` right after `after` (at the very start when nil); false when `after` is not held.
    private mutating func insert(_ item: RemoteItem, after: String?) -> Bool {
        guard let after else {
            if let first = runs.first, first.turnID == item.turnId {
                first.items.insert(item, at: 0)
                first.version += 1
                runOf[item.id] = first
                return true
            }
            let run = Run(turnID: item.turnId, items: [item])
            runs.insert(run, at: 0)
            runOf[item.id] = run
            return true
        }
        guard let run = runOf[after], let position = run.items.firstIndex(where: { $0.id == after }) else { return false }
        if run.turnID == item.turnId {
            run.items.insert(item, at: position + 1)
            run.version += 1
            runOf[item.id] = run
            return true
        }
        guard let runIndex = runs.firstIndex(where: { $0 === run }) else { return false }
        if position == run.items.count - 1 {
            if runIndex + 1 < runs.count, runs[runIndex + 1].turnID == item.turnId {
                let next = runs[runIndex + 1]
                next.items.insert(item, at: 0)
                next.version += 1
                runOf[item.id] = next
                return true
            }
            let added = Run(turnID: item.turnId, items: [item])
            runs.insert(added, at: runIndex + 1)
            runOf[item.id] = added
            return true
        }
        // Inside another turn's run: the run splits around it.
        let tail = Run(turnID: run.turnID, items: Array(run.items[(position + 1)...]))
        run.items.removeSubrange((position + 1)...)
        run.version += 1
        for moved in tail.items { runOf[moved.id] = tail }
        let added = Run(turnID: item.turnId, items: [item])
        runs.insert(contentsOf: [added, tail], at: runIndex + 1)
        runOf[item.id] = added
        return true
    }

    /// Joins runs of one turn that a removal or a move left side by side.
    private mutating func mergeNeighbors() {
        var index = 1
        while index < runs.count {
            let previous = runs[index - 1], run = runs[index]
            guard previous.turnID == run.turnID else {
                index += 1
                continue
            }
            previous.items += run.items
            previous.version += 1
            for item in run.items { runOf[item.id] = previous }
            runs.remove(at: index)
        }
    }

    private static func runs(of items: [RemoteItem]) -> [Run] {
        var runs: [Run] = []
        for item in items {
            if let last = runs.last, last.turnID == item.turnId {
                last.items.append(item)
            } else {
                runs.append(Run(turnID: item.turnId, items: [item]))
            }
        }
        return runs
    }
}
