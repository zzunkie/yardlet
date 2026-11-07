#if DEBUG
import Foundation

/// How many of the conversation's heavier objects were made and how many are still alive, for the
/// performance bench's memory runs (`PerfBenchFixture`). Each object is held weakly, so counting it
/// never keeps it alive; the dead ones are found and counted as released when a snapshot is taken.
/// Off unless the app was launched with `--ui-fixture-perf-memory-census`, and absent from release
/// builds.
@MainActor
enum PerfMemoryCensus {
    enum Category: String, CaseIterable, Sendable {
        /// A task's own hosting view a window made (`TaskSurfaceHostings`), not one it kept.
        case taskSurfaceHosting
        /// A turn's hosting (`ConversationTurnHosting`).
        case conversationTurnHosting
        /// A turn's hosting controller.
        case conversationTurnController
        /// A turn's hosting view, counted where a turn view puts it in place.
        case conversationTurnView
        /// A message's prose view (`TranscriptProseContainerView`).
        case transcriptProseContainer
        /// The prose view's text view (`TranscriptProseTextView`).
        case transcriptProseTextView
        /// The text view's TextKit 2 layout manager.
        case transcriptProseLayoutManager
    }

    static let argument = "--ui-fixture-perf-memory-census"
    static let isEnabled = CommandLine.arguments.contains(argument)

    private struct Weak {
        weak var object: AnyObject?
    }

    private struct Tally {
        var live: [ObjectIdentifier: Weak] = [:]
        var created = 0
        var released = 0
    }

    private static var tallies: [Category: Tally] = [:]

    /// Counts `object` as made in `category`; the same object still alive is counted once.
    static func track(_ object: AnyObject?, _ category: Category) {
        guard isEnabled, let object else { return }
        // In place, so the category's table is not copied for each object.
        track(object, in: &tallies[category, default: Tally()])
    }

    private static func track(_ object: AnyObject, in tally: inout Tally) {
        let id = ObjectIdentifier(object)
        if let existing = tally.live[id] {
            if existing.object === object { return }
            // The object counted under this identifier is gone and its address was reused.
            tally.released += 1
        }
        tally.live[id] = Weak(object: object)
        tally.created += 1
    }

    /// Each category's objects made, still alive and released so far, by the category's name:
    /// `["transcriptProseContainer": ["created": 120, "live": 40, "released": 80], ...]`. Forgets the
    /// objects that are gone and keeps no earlier snapshot.
    static func snapshot() -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for category in Category.allCases {
            var tally = tallies.removeValue(forKey: category) ?? Tally()
            let before = tally.live.count
            tally.live = tally.live.filter { $0.value.object != nil }
            tally.released += before - tally.live.count
            if isEnabled { tallies[category] = tally }
            result[category.rawValue] = ["created": tally.created, "live": tally.live.count, "released": tally.released]
        }
        return result
    }
}
#endif
