import Foundation
import Observation
import YardletRemote

/// One conversation the phone follows (docs/REMOTE_PROTOCOL.md §4.2, §5.3): the items it holds, in runs of one turn
/// each (`RemoteConversationItems`, the same store the Mac's own client keeps). A change rebuilds only the runs it
/// touched; every other turn keeps the value drawn before, so the list redraws only what changed.
@MainActor
@Observable
final class ConversationState {
    /// One run of a turn's items as the screen draws it. Equal while its run did not change.
    struct Turn: Identifiable, Equatable {
        let id: ObjectIdentifier
        /// Held so its identifier is not reused while a drawn turn names it.
        let run: RemoteConversationItems.Run
        let turnID: String
        let version: Int
        let items: [RemoteItem]

        static func == (lhs: Turn, rhs: Turn) -> Bool { lhs.id == rhs.id && lhs.version == rhs.version }

        var header: RemoteItem? { items.first { $0.kind == .turn } }
    }

    let taskID: String
    private(set) var turns: [Turn] = []
    /// Messages waiting in the task's follow-up queue, drawn above the composer (§6.2, §15.15).
    private(set) var queued: [RemoteItem] = []
    /// The first page arrived.
    private(set) var isLoaded = false
    /// The Mac no longer lists the task.
    private(set) var isGone = false
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    /// What lines opened so far hold (§15.8), by item ID.
    private(set) var details: [String: RemoteItemDetail] = [:]
    /// Finished turns whose work the person opened.
    var openedWork: Set<String> = []

    @ObservationIgnored private(set) var cursor: String?
    @ObservationIgnored private var items = RemoteConversationItems()
    @ObservationIgnored private var drawn: [ObjectIdentifier: Turn] = [:]
    @ObservationIgnored private var loadingDetails: Set<String> = []

    init(taskID: String) {
        self.taskID = taskID
    }

    /// A fresh page: `subscribeTask`'s answer or `conversationReset`.
    func load(_ page: [RemoteItem], cursor: String?, hasOlder: Bool) {
        items.replace(with: page)
        drawn = [:]
        self.cursor = cursor
        self.hasOlder = hasOlder
        isLoaded = true
        isLoadingOlder = false
        publish()
    }

    /// A `loadOlder` page.
    func prepend(_ page: [RemoteItem], cursor: String?, hasOlder: Bool) {
        items.prepend(page)
        self.cursor = cursor
        self.hasOlder = hasOlder
        isLoadingOlder = false
        publish()
    }

    /// A `conversation` event's changes. False when the phone is out of step and should subscribe again.
    func apply(_ changes: [RemoteChange]) -> Bool {
        guard items.apply(changes) else { return false }
        publish()
        return true
    }

    func setLoadingOlder(_ loading: Bool) {
        isLoadingOlder = loading
    }

    func markGone() {
        isGone = true
        isLoaded = true
    }

    /// Whether a line's detail should be read now; false while it is read or once it was.
    func beginLoadingDetail(_ itemID: String) -> Bool {
        guard details[itemID] == nil, !loadingDetails.contains(itemID) else { return false }
        loadingDetails.insert(itemID)
        return true
    }

    func cancelLoadingDetail(_ itemID: String) {
        loadingDetails.remove(itemID)
    }

    func setDetail(_ detail: RemoteItemDetail, for itemID: String) {
        loadingDetails.remove(itemID)
        details[itemID] = detail
    }

    /// The requests still waiting, at the end of the latest turn.
    var pendingRequests: [RemoteItem] {
        guard let last = turns.last else { return [] }
        return last.items.filter { $0.kind == .approval && $0.status == "pending" }
    }

    private func publish() {
        var turns: [Turn] = []
        var queued: [RemoteItem] = []
        var drawn: [ObjectIdentifier: Turn] = [:]
        turns.reserveCapacity(items.runs.count)
        for run in items.runs {
            let id = ObjectIdentifier(run)
            let turn: Turn
            if let previous = self.drawn[id], previous.version == run.version {
                turn = previous
            } else {
                turn = Turn(id: id, run: run, turnID: run.turnID, version: run.version, items: run.items.filter { $0.queued != true })
            }
            drawn[id] = turn
            if !turn.items.isEmpty { turns.append(turn) }
        }
        // Queued messages sit at the end of the last turn (§6.2).
        if let last = items.runs.last { queued = last.items.filter { $0.queued == true } }
        self.drawn = drawn
        if turns != self.turns { self.turns = turns }
        if queued != self.queued { self.queued = queued }
    }
}
