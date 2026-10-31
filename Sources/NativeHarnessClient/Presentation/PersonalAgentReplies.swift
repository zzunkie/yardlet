import Foundation
import Observation

/// One reply thread as the room's reply dialog shows it: its root, when known, then its replies. Its
/// own pages are read on their own cursor, apart from the room's, and only ever added to.
@MainActor @Observable
final class PersonalAgentReplyThread {
    /// Where the thread's earlier pages stand: none read yet, another before a cursor, or none left.
    enum Cursor: Equatable { case unread, before(String), end }

    let rootID: String
    /// The root first when it is known, then the delivered replies by time.
    private(set) var messages: [PersonalAgentMessage] = []
    var cursor: Cursor = .unread
    var isLoadingOlder = false
    var olderFailure: PersonalAgentFailure?
    /// Why the last read of the thread again, from its latest page, failed; what was shown stays.
    var latestFailure: PersonalAgentFailure?
    /// The earliest reply the thread's pages returned, which reading it again reaches back to.
    @ObservationIgnored var oldestRead: String?
    /// What the thread's own pages read, kept beside the room's messages, each with the epoch its
    /// read started at (`PersonalAgentReplies.beginRead`).
    @ObservationIgnored var read: [String: (message: PersonalAgentMessage, epoch: Int)] = [:]
    /// The order the pages were read in, for replies without a time.
    @ObservationIgnored var readOrder: [String] = []
    @ObservationIgnored var olderLoad: UUID?
    @ObservationIgnored var latestLoad: UUID?
    /// A newer page was asked for while one was being read; it is read once that one ends.
    @ObservationIgnored var wantsLatest = false

    init(rootID: String) { self.rootID = rootID }

    var hasRead: Bool { cursor != .unread }

    func show(_ value: [PersonalAgentMessage]) {
        if value != messages { messages = value }
    }

    /// Adds a page's messages, read by a read that started at `epoch`. A deleted reply that names no
    /// thread is the one it was read for.
    func ingest(_ page: [PersonalAgentMessage], epoch: Int) {
        for var message in page {
            if message.isDeleted, message.id != rootID, message.replyToMessageID == nil, message.replyRootMessageID == nil {
                message.replyRootMessageID = rootID
            }
            if let existing = read[message.id] {
                // A page that answers late does not bring back what a read started after it changed or deleted.
                if message.supersedes(existing.message, epoch: epoch, otherEpoch: existing.epoch) {
                    read[message.id] = (message, epoch)
                }
            } else {
                read[message.id] = (message, epoch)
                readOrder.append(message.id)
            }
        }
    }
}

/// What a reply quotes of the message it answers.
enum PersonalAgentReplyQuote: Equatable {
    case text(String)
    case attachment
    case deleted
}

/// A conversation's replies: which message belongs to which thread, the count under each message
/// that has replies, and the threads read so far. Room pages, reply pages and confirmed sends all
/// feed one set of messages by identity, a request ID standing for the message it became. It is
/// worked out once per read or send (`reconcile`); the views only look things up.
@MainActor @Observable
final class PersonalAgentReplies {
    /// The thread open over the composer and the message a reply there answers. Only what the window
    /// shows: it is not saved, and a message already sent keeps the target it was sent with.
    struct Focus: Equatable {
        let rootID: String
        let targetID: String

        var target: PersonalAgentReplyTarget { .init(messageID: targetID, rootID: rootID) }
    }

    var focus: Focus?
    /// The indicator under each shown message that has one: a number only while every reply to it
    /// can be counted, nil where it cannot. A message without an entry shows none.
    private(set) var indicators: [String: Int?] = [:]
    /// Shown replies whose quote of the message they answer shows above them: those not following
    /// a message of their own thread.
    private(set) var quoted: Set<String> = []
    @ObservationIgnored private(set) var threads: [String: PersonalAgentReplyThread] = [:]

    private struct Relation { var parentID: String?; var rootID: String? }
    @ObservationIgnored private var known: [String: PersonalAgentMessage] = [:]
    @ObservationIgnored private var order: [String: Int] = [:]
    @ObservationIgnored private var relations: [String: Relation] = [:]
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var roots: [String: String] = [:]
    @ObservationIgnored private var members: [String: [String]] = [:]
    @ObservationIgnored private(set) var roomIDs: Set<String> = []
    /// The epoch each read started at, counted up for every room page, thread page and send, so two
    /// reads the provider's times cannot order are ordered by which began later.
    @ObservationIgnored private var epochCounter = 0
    /// The epoch of the read each room or sent copy came from.
    @ObservationIgnored private var roomEpochs: [String: Int] = [:]
    @ObservationIgnored private var sentEpochs: [String: Int] = [:]
    /// The epoch of the read each standing copy came from.
    @ObservationIgnored private var knownEpochs: [String: Int] = [:]

    /// Starts a read or a send: its results are ordered after anything started before.
    func beginRead() -> Int {
        epochCounter += 1
        return epochCounter
    }

    /// The room's window now holds these copies, from the read that started at `epoch`.
    func noteRoom(_ messages: [PersonalAgentMessage], epoch: Int) {
        for message in messages { roomEpochs[message.id] = epoch }
    }

    /// A confirmed send's response, for the send that started at `epoch`.
    func noteSent(_ message: PersonalAgentMessage, epoch: Int) { sentEpochs[message.id] = epoch }

    /// The message, as the latest read has it: a deletion anywhere stands over an earlier copy.
    func message(_ id: String) -> PersonalAgentMessage? { known[canonical(id)] }

    /// What `reply` quotes of its parent: the parent itself where it is read, else what the provider
    /// embedded, else nothing.
    func quote(for reply: PersonalAgentMessage) -> PersonalAgentReplyQuote? {
        guard let parentID = reply.replyToMessageID else { return nil }
        if let parent = message(parentID) {
            if parent.isDeleted { return .deleted }
            return parent.text.isEmpty ? (parent.attachments.isEmpty ? nil : .attachment)
                : .text(String(parent.text.prefix(PersonalAgentReplyPreview.characterLimit)))
        }
        guard let preview = reply.replyPreview else { return nil }
        if preview.isDeleted { return .deleted }
        return preview.text.isEmpty ? (preview.hasAttachments ? .attachment : nil) : .text(preview.text)
    }

    /// Whether the message is in the room's own loaded window, where its questions are answered.
    func isInRoom(_ id: String) -> Bool { roomIDs.contains(canonical(id)) }

    /// The thread `messageID` belongs to: its named root, else its parent's, followed back.
    func rootOf(_ messageID: String) -> String {
        var current = canonical(messageID)
        var seen: [String] = []
        var cycle = false
        while true {
            if let memo = roots[current] { current = memo; break }
            seen.append(current)
            guard let relation = relations[current], let next = relation.rootID ?? relation.parentID else { break }
            let step = canonical(next)
            if seen.contains(step) { cycle = true; break }
            current = step
        }
        if !cycle { for id in seen { roots[id] = current } }
        return current
    }

    func canonical(_ id: String) -> String {
        var current = id
        var seen: Set<String> = []
        while let next = aliases[current], seen.insert(current).inserted { current = next }
        return current
    }

    /// Opens the thread `messageID` belongs to, replying to `targetID` (the message itself unless
    /// given). Returns the thread, seeded with what is already read.
    @discardableResult
    func open(_ messageID: String, target targetID: String? = nil) -> PersonalAgentReplyThread {
        let root = rootOf(messageID)
        let thread = thread(root)
        focus = .init(rootID: root, targetID: canonical(targetID ?? messageID))
        return thread
    }

    func thread(_ root: String) -> PersonalAgentReplyThread {
        if let thread = threads[root] { return thread }
        let thread = PersonalAgentReplyThread(rootID: root)
        threads[root] = thread
        thread.show(snapshot(root))
        return thread
    }

    /// Works everything out again from the room's loaded window (`room`, oldest first), confirmed
    /// sends it does not hold yet (`sent`) and the threads' pages. `completeTail` says the window
    /// was last read up to the latest message; `uncertain` names messages a reply may have been
    /// sent to without its delivery being known.
    func reconcile(room: [PersonalAgentMessage], sent: [PersonalAgentMessage], completeTail: Bool,
                   uncertain: [String]) {
        known = [:]
        order = [:]
        aliases = [:]
        relations = [:]
        roots = [:]
        var sequence = 0
        knownEpochs = [:]
        func take(_ message: PersonalAgentMessage, epoch: Int) {
            if let request = message.requestID, request != message.id { aliases[request] = message.id }
            sequence += 1
            if order[message.id] == nil { order[message.id] = sequence }
            if let existing = known[message.id],
               !message.supersedes(existing, epoch: epoch, otherEpoch: knownEpochs[message.id] ?? 0) { return }
            known[message.id] = message
            knownEpochs[message.id] = epoch
        }
        // The room first only for the order of messages without a time; which copy stands is decided
        // by deletion, the provider's time and when its read started.
        for message in room { take(message, epoch: roomEpochs[message.id] ?? 0) }
        for message in sent { take(message, epoch: sentEpochs[message.id] ?? 0) }
        for thread in threads.values {
            for id in thread.readOrder { if let copy = thread.read[id] { take(copy.message, epoch: copy.epoch) } }
        }
        roomIDs = Set(room.map(\.id))
        for message in known.values where message.replyToMessageID != nil || message.replyRootMessageID != nil {
            relations[message.id] = .init(parentID: message.replyToMessageID.map(canonical),
                                         rootID: message.replyRootMessageID.map(canonical))
        }

        var counts: [String: Int] = [:]
        members = [:]
        for id in relations.keys {
            let root = rootOf(id)
            guard root != id, let message = known[id] else { continue }
            counts[root, default: 0] += message.isDeleted ? 0 : 1
            members[root, default: []].append(id)
        }
        let doubtful = Set(uncertain.map(rootOf))
        let visible = room + sent.filter { !roomIDs.contains($0.id) }
        var shown: [String: Int?] = [:]
        var quotes: Set<String> = []
        var below: String?
        var run = 0
        for message in visible.reversed() {
            let root = rootOf(message.id)
            if root != below { run = 0 }
            if root == message.id, let count = counts[root] {
                let value: Int? = completeTail && roomIDs.contains(root) && !doubtful.contains(root) ? count : nil
                // The replies right below it, all of them, need no indicator.
                if value != run { shown[message.id] = value }
            }
            below = root
            run += 1
        }
        for (index, message) in visible.enumerated() where message.replyToMessageID != nil {
            if index == 0 || rootOf(visible[index - 1].id) != rootOf(message.id) { quotes.insert(message.id) }
        }
        if shown != indicators { indicators = shown }
        if quotes != quoted { quoted = quotes }
        for thread in threads.values { thread.show(snapshot(thread.rootID)) }
        if let focus {
            let root = rootOf(focus.rootID)
            let target = canonical(focus.targetID)
            if root != focus.rootID || target != focus.targetID {
                _ = thread(root)
                self.focus = .init(rootID: root, targetID: target)
            }
        }
    }

    /// `messages` (the room's window, or the confirmed sends with `room` false) with each copy another
    /// read has superseded replaced by the one standing, which keeps the epoch of the read it came
    /// from; nil when none was. Every view of a message then shows the same read of it.
    func standing(_ messages: [PersonalAgentMessage], room: Bool) -> [PersonalAgentMessage]? {
        var result = messages
        var changed = false
        for (index, message) in messages.enumerated() {
            guard let winner = known[message.id], winner != message else { continue }
            result[index] = winner
            changed = true
            if room { roomEpochs[message.id] = knownEpochs[message.id] } else { sentEpochs[message.id] = knownEpochs[message.id] }
        }
        return changed ? result : nil
    }

    /// The root when it is known, then its delivered replies by time, those without one in the
    /// order they were read.
    private func snapshot(_ root: String) -> [PersonalAgentMessage] {
        let replies = (members[root] ?? []).compactMap { known[$0] }.sorted { a, b in
            if let x = a.createdAt, let y = b.createdAt, x != y { return x < y }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
        return (known[root].map { [$0] } ?? []) + replies
    }
}

extension PersonalAgentReplies {
    /// Messages read only in reply threads, not in the room's loaded window.
    var threadOnlyMessages: [PersonalAgentMessage] {
        threads.values.flatMap(\.readOrder).compactMap { id in roomIDs.contains(id) ? nil : message(id) }
    }

    /// Undeleted replies that chose an option of `questionID`, wherever they were read.
    func optionAnswers(to questionID: String) -> [PersonalAgentMessage] {
        let question = canonical(questionID)
        return (members[rootOf(question)] ?? []).compactMap { known[$0] }.filter {
            !$0.isDeleted && $0.replyToMessageID.map(canonical) == question && DotsOptionPicker.selection($0.metadata) != nil
        }
    }

    /// Whether any reply to thread `root` has been read.
    func hasReplies(_ root: String) -> Bool { members[canonical(root)]?.isEmpty == false }

    /// Whether a message the person sent under `requestID` has been read anywhere.
    func hasSent(requestID: String) -> Bool {
        known.values.contains { $0.author == .person && $0.requestID == requestID }
    }
}

extension PersonalAgentCenter {
    /// Works the conversation's replies out again after a read or a send. A reply waiting to be
    /// sent or confirmed, ordinary or an option's, leaves its thread's count unknown.
    func reconcileReplies(_ state: PersonalAgentConversation) {
        var uncertain: [String] = []
        if let target = state.draft.pending?.replyTarget { uncertain.append(target.messageID) }
        if let question = state.optionReply.pending?.replyToMessageID { uncertain.append(question) }
        state.replies.reconcile(room: state.messages, sent: state.sentMessages,
                                completeTail: state.loaded && state.hasCompleteTail, uncertain: uncertain)
        // The room, the threads and the cards show one read of each message: the standing one.
        if let room = state.replies.standing(state.messages, room: true) { state.messages = room }
        if let sent = state.replies.standing(state.sentMessages, room: false) { state.sentMessages = sent }
        // A reply whose delivery was uncertain, read anywhere under its request, has arrived; the count
        // is worked out again without it waiting.
        if let pending = state.draft.pending, !state.draft.isSending, state.replies.hasSent(requestID: pending.requestID) {
            state.draft.accepted(pending.requestID)
            state.replies.reconcile(room: state.messages, sent: state.sentMessages,
                                    completeTail: state.loaded && state.hasCompleteTail,
                                    uncertain: state.optionReply.pending?.replyToMessageID.map { [$0] } ?? [])
        }
        // A focus that moved to a thread found to be a longer one's reads that thread; a read that
        // failed waits for the person to try again.
        if let root = state.replies.focus?.rootID, let thread = state.replies.threads[root], !thread.hasRead,
           !thread.isLoadingOlder, thread.olderFailure == nil, state === conversation {
            Task { await loadOlderReplies() }
        }
    }

    /// Opens the reply dialog on the thread `messageID` belongs to, replying to `target` (the
    /// message itself unless given), and reads its latest page if none was read yet.
    func openReplies(to messageID: String, target: String? = nil) {
        guard let state = conversation else { return }
        let thread = state.replies.open(messageID, target: target)
        if !thread.hasRead, !thread.isLoadingOlder { Task { await loadOlderReplies() } }
    }

    /// Closes the dialog. The draft, its files and the room stay as they are.
    func closeReplies() {
        conversation?.replies.focus = nil
    }

    private func isCurrent(_ state: PersonalAgentConversation, _ thread: PersonalAgentReplyThread,
                           agent: PersonalAgent, generation started: Int) -> Bool {
        started == generation && selectedID == agent.id && conversation === state
            && state.replies.threads[thread.rootID] === thread && !Task.isCancelled
    }

    private func endLoginIfNeeded(_ error: Error, generation started: Int) {
        let failure = error as? PersonalAgentFailure
        guard started == generation, failure == .accountChanged || failure == .signInRequired else { return }
        accept(failure!)
    }

    /// Reads the open thread's next earlier page, or its latest when none was read: one at a time,
    /// and none once its cursor ended. A failure keeps what is shown and waits to be tried again.
    func loadOlderReplies() async {
        guard let agent = selected, let reader = client, let state = conversation,
              let root = state.replies.focus?.rootID else { return }
        let thread = state.replies.thread(root)
        guard !thread.isLoadingOlder, thread.cursor != .end else { return }
        let before: String? = if case let .before(cursor) = thread.cursor { cursor } else { nil }
        let current = generation
        let load = UUID()
        thread.olderLoad = load
        thread.isLoadingOlder = true
        thread.olderFailure = nil
        // This read's own state ends with it, wherever the window is by then; a later read keeps its own.
        defer {
            if thread.olderLoad == load {
                thread.isLoadingOlder = false
                thread.olderLoad = nil
            }
        }
        let epoch = state.replies.beginRead()
        do {
            let page = try await reader.replies(to: root, for: agent, before: before)
            guard isCurrent(state, thread, agent: agent, generation: current), thread.olderLoad == load else { return }
            thread.ingest(page.messages, epoch: epoch)
            if let oldest = page.messages.first(where: { $0.id != root }) { thread.oldestRead = oldest.id }
            // An unchanged cursor ends the thread, as a missing one does; neither is replaced by a guess.
            thread.cursor = page.before.flatMap { $0 == before ? nil : .before($0) } ?? .end
            thread.isLoadingOlder = false
            thread.olderLoad = nil
            reconcileReplies(state)
            syncInputRequests(state, agent: agent)
        } catch {
            endLoginIfNeeded(error, generation: current)
            guard isCurrent(state, thread, agent: agent, generation: current), thread.olderLoad == load else { return }
            thread.olderFailure = error as? PersonalAgentFailure ?? .network
        }
    }

    /// Reads the open thread again from its latest page back to the earliest reply read before, so
    /// a change to any reply shown is read, when the room's subscription says it changed or the person
    /// asks. What it reads is added: earlier pages, their cursor and anything a page leaves out stay. A
    /// failure keeps what is shown and says so, for the person to try again.
    func refreshFocusedReplies() async {
        guard let agent = selected, let reader = client, let state = conversation,
              let root = state.replies.focus?.rootID, let thread = state.replies.threads[root], thread.hasRead else { return }
        guard thread.latestLoad == nil else { thread.wantsLatest = true; return }
        let current = generation
        let load = UUID()
        thread.latestLoad = load
        defer { if thread.latestLoad == load { thread.latestLoad = nil } }
        let epoch = state.replies.beginRead()
        let boundary = thread.oldestRead.flatMap { thread.read[$0]?.message }
        var read: [PersonalAgentMessage] = []
        // Reaching the earliest reply read before, or the thread's end, is a whole read; a failed page,
        // a cursor that comes back, or the pages running out before either is not.
        var failure: PersonalAgentFailure? = .invalidResponse
        var before: String?
        var visited: Set<String> = []
        for _ in 0..<50 {
            let page: PersonalAgentPage
            do { page = try await reader.replies(to: root, for: agent, before: before) } catch {
                endLoginIfNeeded(error, generation: current)
                failure = error as? PersonalAgentFailure ?? .network
                break
            }
            guard isCurrent(state, thread, agent: agent, generation: current), thread.latestLoad == load else { return }
            read = page.messages + read
            func reachesBoundary() -> Bool {
                guard let boundary else { return true }
                if page.messages.contains(where: { $0.id == boundary.id }) { return true }
                if let target = boundary.createdAt, let start = page.messages.first(where: { $0.id != root })?.createdAt {
                    return start <= target
                }
                return false
            }
            guard !page.messages.isEmpty, !reachesBoundary(), let next = page.before else { failure = nil; break }
            guard visited.insert(next).inserted else { break }
            before = next
        }
        guard isCurrent(state, thread, agent: agent, generation: current), thread.latestLoad == load else { return }
        // What was read is newer than what is shown, even when a later page failed.
        thread.ingest(read, epoch: epoch)
        thread.latestFailure = failure
        if !read.isEmpty {
            reconcileReplies(state)
            syncInputRequests(state, agent: agent)
        }
        thread.latestLoad = nil
        if thread.wantsLatest {
            thread.wantsLatest = false
            await refreshFocusedReplies()
        }
    }

    /// Reads thread `root` afresh in this call, from its latest page back until `messageID` is among
    /// what it returned, or, when `messageID` is the root, which pages need not hold, until the
    /// thread ends: at most ten pages, each cursor once. The messages read, or nil when a page failed,
    /// the thread ended without the message, the pages ran out or the window moved on meanwhile.
    func readThread(_ root: String, until messageID: String) async -> [PersonalAgentMessage]? {
        guard let agent = selected, let reader = client, let state = conversation else { return nil }
        let thread = state.replies.thread(root)
        let current = generation
        let epoch = state.replies.beginRead()
        var before: String?
        var visited: Set<String> = []
        var read: [PersonalAgentMessage] = []
        for _ in 0..<10 {
            let page: PersonalAgentPage
            do { page = try await reader.replies(to: root, for: agent, before: before) } catch {
                endLoginIfNeeded(error, generation: current)
                return nil
            }
            guard isCurrent(state, thread, agent: agent, generation: current) else { return nil }
            read = page.messages + read
            let found = messageID == root ? page.before == nil : page.messages.contains { $0.id == messageID }
            if found {
                thread.ingest(read, epoch: epoch)
                reconcileReplies(state)
                syncInputRequests(state, agent: agent)
                return read
            }
            guard let next = page.before, visited.insert(next).inserted else { return nil }
            before = next
        }
        return nil
    }
}
