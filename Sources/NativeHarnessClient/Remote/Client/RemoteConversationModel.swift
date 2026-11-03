import Foundation
import Observation
import YardletRemote

/// One conversation a client follows on a host (docs/REMOTE_PROTOCOL.md §4.2, §5.3): the items it holds,
/// and the conversation the timeline draws from them. An event projects again only the turns it changed
/// (`RemoteConversationItems.Run.version`); every other turn is the one drawn before, so the timeline
/// draws only what changed.
@MainActor
@Observable
final class RemoteConversationModel {
    let taskID: String
    private(set) var harness: HarnessKind
    private(set) var presentation: ConversationPresentation
    /// Messages waiting in the task's follow-up queue, drawn as chips above the composer (§6.2, §15.15).
    private(set) var queued: [RemoteItem] = []
    /// The first page arrived.
    private(set) var isLoaded = false
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    /// What lines opened so far hold (§15.8), by item ID.
    private(set) var details: [String: RemoteItemDetail] = [:]
    /// Each suggested task's item, which says what became of it (§15.9), by suggestion ID: the chips read
    /// it as they draw.
    private(set) var suggestions: [String: RemoteItem] = [:]

    @ObservationIgnored private(set) var cursor: String?
    @ObservationIgnored private var items = RemoteConversationItems()
    @ObservationIgnored private var projected: [ObjectIdentifier: Projected] = [:]
    @ObservationIgnored private var loadingDetails: Set<String> = []
    @ObservationIgnored var hostName: String
    /// How many turns were projected so far: a change projects only the turns it touched.
    @ObservationIgnored private(set) var projectedTurnCount = 0
    /// Bumped whenever what it holds changes, so the window's cache writes it again only then.
    @ObservationIgnored private(set) var revision = 0

    init(taskID: String, harness: HarnessKind, hostName: String) {
        self.taskID = taskID
        self.harness = harness
        self.hostName = hostName
        presentation = ConversationPresentation(harness: harness, turns: [])
    }

    /// A fresh page: `subscribeTask`'s answer or `conversationReset`.
    func load(_ page: [RemoteItem], cursor: String?, hasOlder: Bool) {
        items.replace(with: page)
        projected = [:]
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

    /// A `conversation` event; false when the client is out of step and must subscribe again.
    func apply(_ changes: [RemoteChange]) -> Bool {
        guard items.apply(changes) else { return false }
        publish()
        return true
    }

    func setLoadingOlder(_ loading: Bool) {
        if isLoadingOlder != loading { isLoadingOlder = loading }
    }

    /// Asked once per line, until it arrives or the asking fails.
    func beginLoadingDetail(_ itemID: String) -> Bool {
        guard details[itemID] == nil, !loadingDetails.contains(itemID) else { return false }
        loadingDetails.insert(itemID)
        return true
    }

    /// A read the connection cut off, so the line asks again.
    func cancelLoadingDetail(_ itemID: String) {
        loadingDetails.remove(itemID)
    }

    func setDetail(_ detail: RemoteItemDetail?, for itemID: String) {
        loadingDetails.remove(itemID)
        details[itemID] = detail ?? RemoteItemDetail()
        if let run = items.run(containing: itemID) { run.version += 1 }
        publish()
    }

    func renameHost(_ name: String) {
        hostName = name
    }

    /// The pending request item a card answered, which says how it is answered.
    func pendingRequest(_ requestID: String) -> RemoteItem? {
        for run in items.runs.reversed() {
            if let item = run.items.last(where: { $0.requestId == requestID && $0.kind == .approval }) { return item }
        }
        return nil
    }

    /// The latest whole turns within a page's limits, for the window's cache (`RemoteHostCache`).
    func latestItems(within limits: RemoteConversationWindow.Limits) -> (items: [RemoteItem], isWhole: Bool) {
        items.latest(within: limits)
    }

    /// The latest turn's plan limit, with what its card offers (§15.17).
    var usageLimit: RemoteItem? {
        guard let last = items.runs.last else { return nil }
        return last.items.last { $0.kind == .error && $0.errorKind == "usageLimit" && $0.inWork != true }
    }

    /// A run as it was last projected: its turn, and its suggested tasks' items.
    private struct Projected {
        var version: Int
        var turn: ConversationTurn
        var suggestions: [RemoteItem]
    }

    private func publish() {
        revision += 1
        var turns: [ConversationTurn] = []
        turns.reserveCapacity(items.runs.count)
        var kept: [ObjectIdentifier: Projected] = [:]
        var seen: Set<String> = []
        var pending: Set<String> = []
        var suggestions: [String: RemoteItem] = [:]
        for run in items.runs {
            let key = ObjectIdentifier(run)
            let entry: Projected
            if let cached = projected[key], cached.version == run.version {
                entry = cached
            } else {
                entry = Projected(version: run.version,
                                  turn: RemoteTurnProjection.turn(run.items, turnID: run.turnID, details: details, hostName: hostName),
                                  suggestions: run.items.filter { $0.suggestionId != nil })
                projectedTurnCount += 1
            }
            kept[key] = entry
            for item in entry.suggestions { if let id = item.suggestionId { suggestions[id] = item } }
            var turn = entry.turn
            // A turn the host sent in two places mid-change still draws once each.
            if !seen.insert(turn.id).inserted {
                turn = ConversationTurn(id: "\(turn.id)#\(turns.count)", status: turn.status, timing: turn.timing)
            }
            for request in turn.requests { pending.insert(request.id) }
            turns.append(turn)
        }
        projected = kept
        var next = ConversationPresentation(harness: harness, turns: turns)
        next.earlier = hasOlder ? .provider(cursor: cursor ?? "") : .none
        next.pendingRequestIDs = pending
        presentation = next
        if suggestions != self.suggestions { self.suggestions = suggestions }
        let waiting = items.runs.last?.items.filter { $0.queued == true } ?? []
        if waiting != queued { queued = waiting }
    }
}
