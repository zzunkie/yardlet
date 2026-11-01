import Foundation

/// Which items of a turn's work are status lines, and which of them fold together.
enum ConversationWorkGrouping {
    enum Run: Identifiable {
        case single(ConversationItem)
        case group([ConversationItem])
        /// Consecutive suggested tasks, one card as the Claude app aggregates its `spawn_task` chips.
        case suggestions([ConversationItem])

        var id: String {
            switch self {
            case let .single(item): item.id
            case let .group(items): "group-" + (items.first?.id ?? "")
            case let .suggestions(items): "suggestions-" + (items.first?.id ?? "")
            }
        }
    }

    /// What a run of work holds: a call, or the provider's thinking among its calls. Thinking does not
    /// part the calls around it, as the Codex app leaves its reasoning out of what splits its activity
    /// group (26.1021) and the Claude app keeps a call's thinking with the call. What counts as a call,
    /// and what a run's summary counts, stays `ConversationWorkSummary.category`'s.
    static func joinsRun(_ item: ConversationItem) -> Bool {
        if case .reasoning = item.kind { return true }
        return ConversationWorkSummary.category(of: item) != nil
    }

    /// Thinking with something to read: it streams, or it has a summary or words of its own. Codex
    /// sends reasoning with neither, which draws nothing.
    static func showsThought(_ item: ConversationItem) -> Bool {
        guard case let .reasoning(summary, detail, isStreaming) = item.kind else { return false }
        return isStreaming || summary?.isEmpty == false || detail?.isEmpty == false
    }

    /// Consecutive calls, two or more, become one group that keeps the thinking among and around
    /// them where it came, and consecutive suggested tasks one card; everything else stays as it is,
    /// the thinking beside a single call too.
    static func runs(_ items: [ConversationItem]) -> [Run] {
        var runs: [Run] = []
        var pending: [ConversationItem] = []
        func flush() {
            let calls = pending.filter { ConversationWorkSummary.category(of: $0) != nil }
            if calls.count > 1 {
                // Thinking with nothing to read takes no cell of the group.
                runs.append(.group(pending.filter { ConversationWorkSummary.category(of: $0) != nil || showsThought($0) }))
            } else {
                runs += pending.map(Run.single)
            }
            pending = []
        }
        for item in items {
            if joinsRun(item) {
                pending.append(item)
            } else if case .taskSuggestion = item.kind {
                flush()
                if case let .suggestions(previous)? = runs.last {
                    runs[runs.count - 1] = .suggestions(previous + [item])
                } else {
                    runs.append(.suggestions([item]))
                }
            } else {
                flush()
                runs.append(.single(item))
            }
        }
        flush()
        return runs
    }

    /// Where each of `runs(items)` lies in `items`: the indices of the items it was made from, thinking
    /// a group leaves out included. Cut at these bounds, the parts of `items` group into the same runs.
    static func runBounds(_ items: [ConversationItem]) -> [Range<Int>] {
        var bounds: [Range<Int>] = []
        var pendingStart: Int?
        var pendingCalls = 0
        var lastIsSuggestions = false
        func flush(at end: Int) {
            guard let start = pendingStart else { return }
            if pendingCalls > 1 {
                bounds.append(start..<end)
            } else {
                bounds += (start..<end).map { $0..<($0 + 1) }
            }
            pendingStart = nil
            pendingCalls = 0
            lastIsSuggestions = false
        }
        for (index, item) in items.enumerated() {
            if joinsRun(item) {
                if pendingStart == nil { pendingStart = index }
                if ConversationWorkSummary.category(of: item) != nil { pendingCalls += 1 }
            } else if case .taskSuggestion = item.kind {
                flush(at: index)
                if lastIsSuggestions, let last = bounds.last {
                    bounds[bounds.count - 1] = last.lowerBound..<(index + 1)
                } else {
                    bounds.append(index..<(index + 1))
                }
                lastIsSuggestions = true
            } else {
                flush(at: index)
                bounds.append(index..<(index + 1))
                lastIsSuggestions = false
            }
        }
        flush(at: items.count)
        return bounds
    }

    /// What a folded turn keeps of its work (`ConversationTurn.workKeptWhenFolded`) but the calls the
    /// live line stands for, in the runs the listed work has: consecutive calls still one summary line,
    /// suggested tasks one card.
    static func runsKeptWhenFolded(_ turn: ConversationTurn, live: ConversationLiveWork?) -> [Run] {
        let liveIDs = Set(live?.items.map(\.id) ?? [])
        return runs(turn.workKeptWhenFolded.filter { !liveIDs.contains($0.id) })
    }
}
