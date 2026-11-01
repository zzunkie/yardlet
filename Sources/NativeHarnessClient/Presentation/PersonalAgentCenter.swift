import Foundation
import Observation

@MainActor @Observable
final class PersonalAgentConversation {
    let draft: PersonalAgentDraft
    /// An option question's answer waiting to be confirmed, kept apart from the draft.
    let optionReply: PersonalAgentOptionReply
    /// The input requests the loaded messages carry, by message.
    var requests: [String: PersonalAgentInputRequest] = [:]
    var messages: [PersonalAgentMessage] = []
    var sentMessages: [PersonalAgentMessage] = []
    var visibleMessages: [PersonalAgentMessage] {
        let known = Set(messages.map(\.id))
        return messages + sentMessages.filter { !known.contains($0.id) }
    }
    var before: String?
    var anchor: String?
    var loaded = false
    var isLoading = false
    /// The room's lifecycle as last read; an unknown or missing one keeps the earlier value.
    var roomLifecycle: String?
    /// Whether the room takes files; the picker, a drop, a paste, a retry and Send all ask this.
    var allowsAttachments: Bool { DotsProjection.allowsAttachments(lifecycle: roomLifecycle) }
    /// Whether a reply can be sent here: the provider gates replies on the same lifecycle as files.
    /// Reading a thread never depends on it.
    var allowsReplies: Bool { DotsProjection.allowsAttachments(lifecycle: roomLifecycle) }
    /// The conversation's reply threads, counts and the reply dialog's focus.
    let replies = PersonalAgentReplies()
    /// The loaded window was last read through to the latest message.
    @ObservationIgnored var hasCompleteTail = false
    @ObservationIgnored var loadID: UUID?
    var failure: PersonalAgentFailure?
    /// Why the last read of earlier messages failed; the conversation stays as it was.
    var olderFailure: PersonalAgentFailure?

    init(draft: PersonalAgentDraft = PersonalAgentDraft(), optionReply: PersonalAgentOptionReply = PersonalAgentOptionReply()) {
        self.draft = draft
        self.optionReply = optionReply
    }
}

/// What the selected dot's details show beside its conversation. Each part loads and fails on its
/// own, so an optional read never blocks the messages; a changed account clears them with the rest.
@MainActor @Observable
final class PersonalAgentDetails {
    enum Part<Value: Equatable>: Equatable {
        case loading, loaded(Value), failed(PersonalAgentFailure)
        var value: Value? { if case let .loaded(value) = self { value } else { nil } }
    }
    var activity: Part<[PersonalAgentActivity]> = .loading
    var activityCursor: String?
    var isLoadingMoreActivity = false
    /// Which refresh is current: a reply to an earlier one, or a later Activity page of it, is dropped.
    @ObservationIgnored var refreshEpoch = 0
    var schedules: Part<[PersonalAgentSchedule]> = .loading
    var computers: Part<[PersonalAgentComputer]> = .loading
    /// What the dot produced, as far as read; a new one with each refresh of the details.
    var outputs: PersonalAgentOutputs?
}

/// The draft files go to, fixed when the person starts choosing them.
struct PersonalAgentFileTarget {
    let agent: PersonalAgent
    let draft: PersonalAgentDraft
    let generation: Int
}

/// A task from the selected dot's Activity, opened to read its execution record. It belongs to the
/// dot and the reading that listed it: another dot, another connection or another login closes it,
/// and a read that outlives it changes nothing.
@MainActor @Observable
final class PersonalAgentActivityReading {
    let agentID: PersonalAgentIdentity
    let activity: PersonalAgentActivity
    var history: PersonalAgentActivityHistory
    @ObservationIgnored fileprivate var tasks: [Task<Void, Never>] = []

    init(agentID: PersonalAgentIdentity, activity: PersonalAgentActivity) {
        self.agentID = agentID
        self.activity = activity
        history = PersonalAgentActivityHistory(threadID: activity.id)
    }

    fileprivate func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}

/// What a screen keeps of a conversation's pictures; the center only tells it when a connection ends.
@MainActor
protocol PersonalAgentThumbnailStore: AnyObject {
    func forgetFailures()
}

/// Window-owned reading state. Switching the shell does not modify the selected
/// coding task, its draft, or provider history. Nothing here writes read receipts.
@MainActor @Observable
final class PersonalAgentCenter {
    private(set) var agents: [PersonalAgent] = []
    private(set) var selectedID: PersonalAgentIdentity?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var failure: PersonalAgentFailure?
    private(set) var isReconnecting = false
    private(set) var sourceKey: String?
    @ObservationIgnored private var draftSourceKey = ""
    @ObservationIgnored private(set) var client: (any PersonalAgentClient)?
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private let drafts: PersonalAgentDrafts
    @ObservationIgnored private let preparer: any PersonalAgentFilePreparing
    /// This window's uploads, by draft file; a changed connection cancels them all.
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    /// The last upload queued for each draft, which the next one waits for: one at a time, in order.
    @ObservationIgnored private var uploadQueues: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The claims and acknowledgements of input-request answers, shared by every window and home.
    @ObservationIgnored let responses: any DotsResponseJournal
    private var conversations: [PersonalAgentIdentity: PersonalAgentConversation] = [:]
    private var detailsByAgent: [PersonalAgentIdentity: PersonalAgentDetails] = [:]
    /// The Activity task open in place of the conversation, if any.
    private(set) var activityReading: PersonalAgentActivityReading?
    /// Profile pictures read in this window, by dot and picture version; memory only.
    private var avatarData: [AvatarKey: Data] = [:]
    @ObservationIgnored private var unavailableAvatars: Set<AvatarKey> = []
    @ObservationIgnored private var avatarTask: Task<Void, Never>?
    /// Sprite sheets read in this window, by pet; each carries its version. Memory only.
    private var spriteSheets: [String: PersonalAgentSpriteSheet] = [:]
    @ObservationIgnored private var unavailableSprites: Set<String> = []
    /// Thumbnails of the conversation's pictures, kept by the screens for this connection's account;
    /// memory only, and dropped when the connection or account changes.
    @ObservationIgnored var thumbnailStore: (any PersonalAgentThumbnailStore)?
    /// What the selected dot is doing, from its room's bound state; idle while none is shown.
    private(set) var liveStatus: PersonalAgentStatus = .idle
    /// The selected dot's motion, kept apart from its words so a new heading redraws no picture.
    private(set) var liveMotion: PersonalAgentSpriteLayout.Motion = .idle
    @ObservationIgnored private var live: Task<Void, Never>?
    /// Which dot and connection the observation is for: asked again for the same, it carries on.
    @ObservationIgnored private var liveKey: (identity: PersonalAgentIdentity, generation: Int)?
    /// Dots whose profile, read paused, has since shown a turn under way in its room: its pause is
    /// older than that, and stands no longer until the profiles are read again.
    private var resumedSinceRead: Set<PersonalAgentIdentity> = []
    /// The views that report the window shows the dots: the room is observed only while one does.
    /// A view replaced by another may report after it, so each speaks only for itself.
    @ObservationIgnored private var visibleReporters: Set<UUID> = []
    private var isVisible: Bool { !visibleReporters.isEmpty }
    /// The reporter a caller that speaks for the whole window uses.
    static let windowReporter = UUID()
    /// The app's watch, told which dot this window shows so it is read and not announced.
    @ObservationIgnored weak var watch: PersonalAgentWatch? {
        didSet { if oldValue !== watch { oldValue?.setShown(nil, by: ObjectIdentifier(self)); reportShown() } }
    }
    /// The dot a notification asked to show, chosen once the agents are read.
    @ObservationIgnored private var preferredID: PersonalAgentIdentity?

    private struct AvatarKey: Hashable {
        let identity: PersonalAgentIdentity
        let version: String
    }

    var selected: PersonalAgent? { agents.first { $0.id == selectedID } }
    var conversation: PersonalAgentConversation? { selectedID.flatMap { conversations[$0] } }
    var details: PersonalAgentDetails? { selectedID.flatMap { detailsByAgent[$0] } }

    /// The picture read for `agent`'s current profile, if any; the view decodes and bounds it.
    func avatar(for agent: PersonalAgent) -> Data? {
        agent.avatar.flatMap { avatarData[AvatarKey(identity: agent.id, version: $0.version)] }
    }

    /// The sheet read for the pet `agent`'s profile names, if any; the view decodes and bounds it.
    func spriteSheet(for agent: PersonalAgent) -> PersonalAgentSpriteSheet? {
        agent.petID.flatMap { spriteSheets[$0] }
    }

    /// The pet's motion for `agent`: only the selected dot's room is observed, so any other is idle.
    func motion(for agent: PersonalAgent) -> PersonalAgentSpriteLayout.Motion {
        agent.id == selectedID ? liveMotion : .idle
    }

    func status(for agent: PersonalAgent) -> PersonalAgentStatus {
        agent.id == selectedID ? liveStatus : PersonalAgentStatus(live: nil, isPaused: isPaused(agent))
    }

    /// Whether `agent` is paused, as far as anything read since its profile says.
    func isPaused(_ agent: PersonalAgent) -> Bool { agent.isPaused && !resumedSinceRead.contains(agent.id) }

    init(drafts: PersonalAgentDrafts = PersonalAgentDrafts(),
         preparer: any PersonalAgentFilePreparing = PersonalAgentUnchangedFiles(),
         responses: any DotsResponseJournal = DotsMemoryResponseJournal()) {
        self.drafts = drafts
        self.preparer = preparer
        self.responses = responses
    }

    /// The window shows the dots, or no longer does (covered, minimized, hidden), as `reporter` sees
    /// it: the selected room is observed only while it does. Its conversation keeps reading either way.
    func setVisible(_ visible: Bool, reporter: UUID = PersonalAgentCenter.windowReporter) {
        let was = isVisible
        if visible { visibleReporters.insert(reporter) } else { visibleReporters.remove(reporter) }
        guard isVisible != was else { return }
        reportShown()
        if isVisible { observeSelected() } else { stopObserving() }
    }

    /// Tells the watch the dot whose conversation the window shows now, if any.
    private func reportShown() {
        watch?.setShown(isVisible ? selectedID : nil, by: ObjectIdentifier(self))
    }

    /// Shows `id` once it is among the agents read: now, if it is, or after the next connection reads it.
    func reveal(_ id: PersonalAgentIdentity) async {
        if agents.contains(where: { $0.id == id }) {
            preferredID = nil
            await select(id)
        } else {
            preferredID = id
        }
    }

    private func observeSelected() {
        if let key = liveKey, live != nil, key.identity == selectedID, key.generation == generation, isVisible { return }
        stopObserving()
        guard isVisible, let agent = selected, let client else { return }
        let current = generation
        liveKey = (agent.id, current)
        live = Task { [weak self] in
            let stream = await client.liveState(for: agent)
            for await update in stream {
                // A state that arrives after the window moved on belongs to nothing shown here.
                guard let self, !Task.isCancelled, self.generation == current, self.selectedID == agent.id else { break }
                switch update {
                case let .state(state): self.showLive(state)
                case let .failed(failure): self.accept(failure)
                }
            }
        }
    }

    private func stopObserving() {
        live?.cancel()
        live = nil
        liveKey = nil
        showLive(nil)
    }

    private func showLive(_ state: PersonalAgentLiveState?) {
        if let agent = selected, agent.isPaused, let thread = state?.threads.first, thread.streamState == .attached,
           thread.isActive == true || thread.isInProgressTurn, !resumedSinceRead.contains(agent.id) {
            // Inserted once: writing the same set again would tell every view of it to redraw.
            resumedSinceRead.insert(agent.id)
        }
        let status = PersonalAgentStatus(live: state, isPaused: selected.map(isPaused) ?? false)
        if status != liveStatus { liveStatus = status }
        if status.motion != liveMotion { liveMotion = status.motion }
    }

    func connect(sourceKey: String, draftSourceKey: String? = nil, makeClient: () -> any PersonalAgentClient) async {
        let sameSource = self.sourceKey == sourceKey
        let oldIdentity = sameSource ? agents.first?.id : nil
        let old = detach()
        let current = generation
        if !sameSource { clear() }
        self.sourceKey = sourceKey
        self.draftSourceKey = draftSourceKey ?? sourceKey
        await old?.stop()
        guard current == generation, !Task.isCancelled else { return }
        let reader = makeClient()
        client = reader
        isLoading = true
        failure = nil
        do {
            let values = try await reader.agents()
            guard current == generation, !Task.isCancelled else { return }
            if let oldIdentity, let next = values.first?.id,
               oldIdentity.accountID != next.accountID || oldIdentity.userID != next.userID {
                throw PersonalAgentFailure.accountChanged
            }
            agents = values
            hasLoaded = true
            isLoading = false
            if let preferredID, values.contains(where: { $0.id == preferredID }) {
                closeActivity()
                selectedID = preferredID
            } else if !values.contains(where: { $0.id == selectedID }) {
                selectedID = values.first(where: \.isPrimary)?.id ?? values.first?.id
            }
            preferredID = nil
            reportShown()
            // A new connection rereads the profiles, whose signed picture locations and pauses may be new.
            resumedSinceRead = []
            unavailableAvatars = []
            unavailableSprites = []
            loadAvatars(values, from: reader, generation: current)
            await showSelected()
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            isLoading = false
            accept(error)
        }
    }

    func select(_ id: PersonalAgentIdentity) async {
        guard agents.contains(where: { $0.id == id }), selectedID != id else { return }
        closeActivity()
        cancelOutputs()
        events?.cancel()
        selectedID = id
        reportShown()
        stopObserving()
        await showSelected()
    }

    private func showSelected() async {
        guard let agent = selected, let client else { return }
        let current = generation
        if conversations[agent.id] == nil {
            conversations[agent.id] = PersonalAgentConversation(draft: drafts.draft(source: draftSourceKey, identity: agent.id),
                optionReply: drafts.optionReply(source: draftSourceKey, identity: agent.id))
        }
        // Each connection reads the details again: an earlier connection's reads were dropped with it.
        refreshDetails()
        await refreshConversation()
        guard selectedID == agent.id, current == generation, !Task.isCancelled else { return }
        events?.cancel()
        events = Task { [weak self] in
            let stream = await client.updates(for: agent)
            for await update in stream {
                guard let self, !Task.isCancelled, self.generation == current, self.selectedID == agent.id else { break }
                switch update {
                case .connected: self.isReconnecting = false
                case .reconnecting: self.isReconnecting = true
                case let .failed(failure): self.accept(failure)
                case .changed:
                    // The open reply thread reads its latest page on the same signal; nothing polls.
                    Task { await self.refreshFocusedReplies() }
                    // Coalesce updates while a bounded read is already in flight.
                    if self.conversation?.isLoading == true { self.pendingRefresh = true }
                    else { await self.refreshConversation() }
                }
            }
        }
        observeSelected()
    }

    /// Reads the latest page again, back to the oldest message shown, or the next earlier page.
    /// True only when this read completed and its result is shown.
    @discardableResult
    func refreshConversation(older: Bool = false) async -> Bool {
        guard let agent = selected, let reader = client, let state = conversations[agent.id], !state.isLoading else { return false }
        let before = older ? state.before : nil
        if older && before == nil { return false }
        let current = generation
        let loadID = UUID()
        let acceptedBeforeRead = Set(state.sentMessages.map(\.id))
        state.loadID = loadID
        state.isLoading = true
        defer {
            if state.loadID == loadID { state.isLoading = false; state.loadID = nil }
        }
        if older { state.olderFailure = nil } else { state.failure = nil }
        var succeeded = false
        let epoch = state.replies.beginRead()
        do {
            let page = try await reader.messages(for: agent, before: before)
            guard current == generation, !Task.isCancelled else { return false }
            let previousIDs = Set(state.messages.map(\.id))
            var incoming = page.messages
            var cursor = page.before
            if !older, state.loaded, !previousIDs.isEmpty {
                var visited = Set<String>()
                let oldest = state.messages.first!
                // Revalidate the displayed range, including old edits/deletions.
                // Separately accepted sends never serve as a history boundary.
                func reachesBoundary() -> Bool {
                    if incoming.contains(where: { $0.id == oldest.id }) { return true }
                    if let target = oldest.createdAt, let start = incoming.first?.createdAt { return start <= target }
                    return false
                }
                while !incoming.isEmpty, !reachesBoundary(), let next = cursor {
                    guard visited.insert(next).inserted else { throw PersonalAgentFailure.invalidResponse }
                    let preceding = try await reader.messages(for: agent, before: next)
                    guard current == generation, !Task.isCancelled else { return false }
                    incoming = DotsProjection.merge(preceding.messages, with: incoming, older: false)
                    cursor = preceding.before
                    if preceding.messages.isEmpty { break }
                }
            }
            state.messages = older ? DotsProjection.merge(state.messages, with: incoming, older: true) : incoming
            state.replies.noteRoom(incoming, epoch: epoch)
            // The Outputs look only at the messages this read returned.
            let outputs = detailsByAgent[agent.id]?.outputs
            outputs?.noteRoom(incoming)
            if !older, let lifecycle = page.roomLifecycle { state.roomLifecycle = lifecycle }
            let confirmed = Set(state.messages.map(\.id))
            // A successful latest read is authoritative even if an accepted
            // message was deleted before that read. Do not retain a ghost copy.
            state.sentMessages.removeAll { confirmed.contains($0.id) || (!older && acceptedBeforeRead.contains($0.id)) }
            if let request = state.draft.pending,
               state.messages.contains(where: { $0.author == .person && $0.requestID == request.requestID }) {
                state.draft.accepted(request.requestID)
            }
            state.before = older && page.messages.allSatisfy({ previousIDs.contains($0.id) }) ? nil : cursor
            state.loaded = true
            outputs?.noteConversation(before: state.before, loaded: true)
            if !older { state.hasCompleteTail = true }
            succeeded = true
            reconcileReplies(state)
            syncInputRequests(state, agent: agent)
        } catch {
            guard current == generation, !Task.isCancelled else { return false }
            let failure = error as? PersonalAgentFailure ?? .network
            if older { state.olderFailure = failure } else { state.failure = failure }
            // A window not read through to the latest message counts no thread for certain.
            if !older, state.hasCompleteTail { state.hasCompleteTail = false; reconcileReplies(state) }
            if failure == .accountChanged || failure == .signInRequired { accept(failure) }
        }
        state.isLoading = false
        if pendingRefresh, current == generation {
            pendingRefresh = false
            await refreshConversation()
        }
        return succeeded
    }

    /// Reads the selected dot's Activity, schedules and computers again, each on its own.
    func refreshDetails() {
        guard let agent = selected, let reader = client else { return }
        let current = generation
        let details = detailsByAgent[agent.id] ?? PersonalAgentDetails()
        detailsByAgent[agent.id] = details
        details.refreshEpoch += 1
        // The Outputs read again from the first of the tasks' work when they are next shown; the
        // conversation's loaded messages are looked at once to begin it.
        details.outputs?.cancel()
        let outputs = PersonalAgentOutputs(roomID: agent.id.roomID)
        if let state = conversations[agent.id], state.loaded {
            outputs.noteRoom(state.messages)
            outputs.noteConversation(before: state.before, loaded: true)
        }
        details.outputs = outputs
        let epoch = details.refreshEpoch
        // The shown list stays; its next page is the old read's, so "Show more" waits for the new first page.
        details.activityCursor = nil
        Task {
            do {
                let page = try await reader.activity(for: agent, cursor: nil)
                guard current == generation, epoch == details.refreshEpoch else { return }
                details.activity = .loaded(page.items)
                details.activityCursor = page.cursor
            } catch {
                if current == generation, epoch == details.refreshEpoch { details.activity = .failed(detailFailure(error)) }
            }
        }
        Task {
            do {
                let values = try await reader.schedules(for: agent)
                if current == generation, epoch == details.refreshEpoch { details.schedules = .loaded(values) }
            } catch {
                if current == generation, epoch == details.refreshEpoch { details.schedules = .failed(detailFailure(error)) }
            }
        }
        Task {
            do {
                let values = try await reader.computers(for: agent)
                if current == generation, epoch == details.refreshEpoch { details.computers = .loaded(values) }
            } catch {
                if current == generation, epoch == details.refreshEpoch { details.computers = .failed(detailFailure(error)) }
            }
        }
    }

    func loadMoreActivity() async {
        guard let agent = selected, let reader = client, let details = detailsByAgent[agent.id],
              let cursor = details.activityCursor, !details.isLoadingMoreActivity, details.activity.value != nil else { return }
        let current = generation
        let epoch = details.refreshEpoch
        details.isLoadingMoreActivity = true
        defer { details.isLoadingMoreActivity = false }
        do {
            let page = try await reader.activity(for: agent, cursor: cursor)
            // A refresh since then replaced the list this page continued.
            guard current == generation, epoch == details.refreshEpoch, let shown = details.activity.value else { return }
            let known = Set(shown.map(\.id))
            details.activity = .loaded(DotsProjection.sortedActivity(shown + page.items.filter { !known.contains($0.id) }))
            details.activityCursor = page.cursor
        } catch {
            if current == generation { _ = detailFailure(error) }
        }
    }

    /// A part's own failure; a changed account or sign-in also ends the whole view, as any read does.
    private func detailFailure(_ error: Error) -> PersonalAgentFailure {
        let failure = error as? PersonalAgentFailure ?? .network
        if failure == .accountChanged || failure == .signInRequired { accept(failure) }
        return failure
    }

    // MARK: Outputs

    /// Begins reading the selected dot's Outputs, once, when they are first shown.
    func startOutputs() {
        guard let (outputs, agent, reader, isCurrent) = currentOutputs() else { return }
        outputs.start(reader: reader, agent: agent, conversationBefore: conversation?.before, isCurrent: isCurrent,
                      failed: { [weak self] in _ = self?.detailFailure($0) })
    }

    /// Reads further back: an earlier page of messages and more of the tasks' work.
    func readEarlierOutputs() {
        guard let (outputs, agent, reader, isCurrent) = currentOutputs() else { return }
        outputs.readEarlier(reader: reader, agent: agent, conversationBefore: conversation?.before, isCurrent: isCurrent,
                            failed: { [weak self] in _ = self?.detailFailure($0) })
    }

    func retryOutputs() {
        guard let (outputs, agent, reader, isCurrent) = currentOutputs() else { return }
        outputs.retry(reader: reader, agent: agent, conversationBefore: conversation?.before, isCurrent: isCurrent,
                      failed: { [weak self] in _ = self?.detailFailure($0) })
    }

    private func currentOutputs() -> (PersonalAgentOutputs, PersonalAgent, any PersonalAgentClient, @MainActor () -> Bool)? {
        guard let agent = selected, let reader = client, let details = detailsByAgent[agent.id],
              let outputs = details.outputs else { return nil }
        let current = generation
        let isCurrent: @MainActor () -> Bool = { [weak self, weak details, weak outputs] in
            guard let self, let details, let outputs, !Task.isCancelled else { return false }
            return self.generation == current && self.selectedID == agent.id
                && self.detailsByAgent[agent.id] === details && details.outputs === outputs
        }
        return (outputs, agent, reader, isCurrent)
    }

    /// The bytes of a file a task left on the dot's computer, for the dot shown on this connection.
    func download(_ file: PersonalAgentRemoteFile, for identity: PersonalAgentIdentity) async throws -> PersonalAgentDownload {
        guard let agent = selected, agent.id == identity, let client else { throw PersonalAgentFailure.stopped }
        let current = generation
        do {
            let value = try await client.outputFile(file, for: agent)
            guard current == generation, selectedID == identity else { throw PersonalAgentFailure.stopped }
            return value
        } catch let error as DotsRemoteFileError {
            // The person is told what failed; the step and code stay with the transport's checks.
            throw error.failure
        } catch {
            if current == generation { _ = detailFailure(error) }
            throw error
        }
    }

    private func cancelOutputs() {
        for details in detailsByAgent.values { details.outputs?.cancel() }
    }

    // MARK: An Activity task's execution record

    /// Opens a task the selected dot's Activity lists. Only a task in that list opens: it is how the
    /// provider's own app knows the task is the dot's, and no other thread is read.
    func openActivity(_ id: String) {
        guard let agent = selected, let details = detailsByAgent[agent.id],
              let activity = details.activity.value?.first(where: { $0.id == id }) else { return }
        if let open = activityReading, open.agentID == agent.id, open.activity.id == id { return }
        closeActivity()
        let reading = PersonalAgentActivityReading(agentID: agent.id, activity: activity)
        activityReading = reading
        startActivity(reading)
    }

    /// Back to the dot's conversation; reads still running are dropped.
    func closeActivity() {
        activityReading?.cancel()
        activityReading = nil
    }

    /// Reads the open task again from its newest turns, as when it opened.
    func reloadActivity() {
        guard let reading = activityReading else { return }
        reading.cancel()
        reading.history = PersonalAgentActivityHistory(threadID: reading.activity.id)
        startActivity(reading)
    }

    /// The turns before the ones read.
    func loadEarlierActivityTurns() {
        guard let (reading, agent, reader) = currentActivity(), !reading.history.isLoadingEarlierTurns,
              let cursor = reading.history.state.thread?.turnsNextCursor else { return }
        reading.history.isLoadingEarlierTurns = true
        reading.history.earlierTurnsFailure = nil
        runActivity(reading) { [weak self] isCurrent in
            do {
                let page = try await reader.activityTurns(reading.activity.id, cursor: cursor, for: agent)
                guard isCurrent() else { return }
                reading.history.isLoadingEarlierTurns = false
                let added = try reading.history.apply(turns: page, after: cursor)
                self?.readFirstItems(of: added, in: reading, agent: agent, reader: reader)
            } catch {
                guard isCurrent() else { return }
                reading.history.isLoadingEarlierTurns = false
                reading.history.earlierTurnsFailure = self?.detailFailure(error)
            }
        }
    }

    /// The next items of one turn: its first page if none were read, else the page after them.
    func loadActivityItems(of turnID: String) {
        guard let (reading, agent, reader) = currentActivity(), !reading.history.loadingItems.contains(turnID) else { return }
        let next = reading.history.itemsToRead(of: turnID)
        guard next.more else { return }
        runActivity(reading) { [weak self] isCurrent in
            await self?.readItems(of: turnID, after: next.cursor, in: reading, agent: agent, reader: reader, isCurrent: isCurrent)
        }
    }

    /// Reads again every turn whose items could not be read.
    func retryActivityItems() {
        guard let reading = activityReading else { return }
        for turnID in reading.history.turns.map(\.id) where reading.history.itemFailures[turnID] != nil {
            loadActivityItems(of: turnID)
        }
    }

    private func startActivity(_ reading: PersonalAgentActivityReading) {
        guard let (_, agent, reader) = currentActivity() else { return }
        let threadID = reading.activity.id
        runActivity(reading) { [weak self] isCurrent in
            do {
                let thread = try await reader.activityThread(threadID, for: agent)
                guard isCurrent() else { return }
                let page = try await reader.activityTurns(threadID, cursor: nil, for: agent)
                guard isCurrent() else { return }
                var history = reading.history
                history.begin(thread)
                let added = try history.apply(turns: page, after: nil)
                reading.history = history
                self?.readFirstItems(of: added, in: reading, agent: agent, reader: reader)
            } catch {
                guard isCurrent() else { return }
                let failure = self?.detailFailure(error) ?? .network
                reading.history.phase = failure == .missing ? .missing : .failed(failure)
            }
        }
    }

    /// The first items of the turns a page added, newest first, each read on its own.
    private func readFirstItems(of turnIDs: [String], in reading: PersonalAgentActivityReading, agent: PersonalAgent,
                                reader: any PersonalAgentClient) {
        for turnID in turnIDs.reversed() {
            runActivity(reading) { [weak self] isCurrent in
                await self?.readItems(of: turnID, after: nil, in: reading, agent: agent, reader: reader, isCurrent: isCurrent)
            }
        }
    }

    private func readItems(of turnID: String, after cursor: String?, in reading: PersonalAgentActivityReading,
                           agent: PersonalAgent, reader: any PersonalAgentClient,
                           isCurrent: @escaping @MainActor () -> Bool) async {
        guard isCurrent(), !reading.history.loadingItems.contains(turnID) else { return }
        reading.history.loadingItems.insert(turnID)
        do {
            let page = try await reader.activityItems(reading.activity.id, turnID: turnID, cursor: cursor, for: agent)
            guard isCurrent() else { return }
            var history = reading.history
            history.loadingItems.remove(turnID)
            try history.apply(items: page, of: turnID, after: cursor)
            reading.history = history
        } catch {
            guard isCurrent() else { return }
            reading.history.loadingItems.remove(turnID)
            reading.history.itemFailures[turnID] = detailFailure(error)
        }
    }

    private func currentActivity() -> (PersonalAgentActivityReading, PersonalAgent, any PersonalAgentClient)? {
        guard let reading = activityReading, let agent = selected, agent.id == reading.agentID,
              let reader = client else { return nil }
        return (reading, agent, reader)
    }

    /// Runs a read of the open task. It applies only while the task is still open, on the same
    /// connection, and was not cancelled.
    private func runActivity(_ reading: PersonalAgentActivityReading,
                             _ body: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void) {
        let current = generation
        let isCurrent: @MainActor () -> Bool = { [weak self, weak reading] in
            guard let self, let reading, !Task.isCancelled else { return false }
            return self.generation == current && self.activityReading === reading && self.selectedID == reading.agentID
        }
        reading.tasks.removeAll { $0.isCancelled }
        reading.tasks.append(Task { await body(isCurrent) })
    }

    private func loadAvatars(_ values: [PersonalAgent], from reader: any PersonalAgentClient, generation current: Int) {
        avatarTask?.cancel()
        let wanted = values.compactMap { agent in agent.avatar.map { (agent, AvatarKey(identity: agent.id, version: $0.version)) } }
        avatarTask = Task { [weak self] in
            for (agent, key) in wanted {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                guard self.avatarData[key] == nil, !self.unavailableAvatars.contains(key) else { continue }
                do {
                    let data = try await reader.avatar(for: agent)
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.avatarData[key] = data
                } catch {
                    // A picture that cannot be read leaves the dot's initial; the messages carry on.
                    guard self.generation == current else { return }
                    self.unavailableAvatars.insert(key)
                }
            }
            // The animated forms after every still picture: a dot without one keeps its picture.
            await self?.loadSpriteSheets(values, from: reader, generation: current)
        }
    }

    private static func endsTheLogin(_ error: Error) -> Bool {
        let failure = error as? PersonalAgentFailure
        return failure == .accountChanged || failure == .signInRequired
    }

    private func loadSpriteSheets(_ values: [PersonalAgent], from reader: any PersonalAgentClient, generation current: Int) async {
        var looked = Set<String>()
        for agent in values {
            // Dots that share a pet share its sheet.
            guard let id = agent.petID, looked.insert(id).inserted else { continue }
            let pet: PersonalAgentPet?
            do { pet = try await reader.pet(id, for: agent) } catch {
                guard generation == current, !Task.isCancelled else { return }
                // Another login clears the whole reading, as the details do; a passing failure keeps
                // what is shown, as reconnecting does.
                if Self.endsTheLogin(error) { return accept(error) }
                continue
            }
            guard generation == current, !Task.isCancelled else { return }
            // A pet gone, or one without a sheet to read, leaves the still picture.
            guard let pet else { spriteSheets[id] = nil; continue }
            let key = id + "|" + pet.version
            guard spriteSheets[id]?.version != pet.version else { continue }
            // A new version that cannot be read does not leave the old one playing.
            spriteSheets[id] = nil
            guard !unavailableSprites.contains(key) else { continue }
            do {
                let data = try await reader.spriteSheet(pet, for: agent)
                guard generation == current, !Task.isCancelled else { return }
                spriteSheets[id] = PersonalAgentSpriteSheet(data: data, version: pet.version)
            } catch {
                guard generation == current else { return }
                if Self.endsTheLogin(error) { return accept(error) }
                unavailableSprites.insert(key)
            }
        }
    }

    func disconnect() async {
        let old = detach()
        await old?.stop()
    }

    /// Where files picked or dropped now go: the shown dot's draft on this connection. Taken when the
    /// person starts choosing, so a dot, account or home chosen before the files arrive never gets them.
    func fileTarget() -> PersonalAgentFileTarget? {
        guard client != nil, let agent = selected, let state = conversation, state.allowsAttachments else { return nil }
        let draft = state.draft
        return .init(agent: agent, draft: draft, generation: generation)
    }

    /// Copies the files into the target's draft, and uploads each once copied.
    func attach(_ sources: [PersonalAgentFileSource], to target: PersonalAgentFileTarget) async {
        await attach(to: target) { await $0.addFiles(sources) }
    }

    /// A pasted picture, as the PNG bytes `encode` makes.
    func attachImage(to target: PersonalAgentFileTarget, encode: @escaping @Sendable () -> Data?) async {
        await attach(to: target) { await $0.addImage(name: "image.png", mimeType: "image/png", encode: encode) }
    }

    private func attach(to target: PersonalAgentFileTarget, _ add: (PersonalAgentDraft) async -> [UUID]) async {
        guard target.generation == generation else { return }
        let added = await add(target.draft)
        // Files copied after the connection changed stay in their own dot's draft, for a retry there.
        for id in added {
            if target.generation == generation { startUpload(id, in: target.draft, for: target.agent) }
            else { target.draft.setState(id, .failed(.uploadInterrupted)) }
        }
    }

    /// Uploads again every file of the selected dot's draft whose upload failed or was interrupted.
    func retryUploads() {
        guard let agent = selected, let state = conversation, state.allowsAttachments else { return }
        let draft = state.draft
        guard draft.pending == nil, !draft.isSending else { return }
        for file in draft.files where file.failure != nil { startUpload(file.id, in: draft, for: agent) }
    }

    /// Removing a file stops its upload here; what the room may already hold stays there.
    func removeFile(_ id: UUID) {
        guard let draft = conversation?.draft, draft.pending == nil, !draft.isSending else { return }
        uploads.removeValue(forKey: id)?.cancel()
        draft.removeFile(id)
    }

    private func startUpload(_ id: UUID, in draft: PersonalAgentDraft, for agent: PersonalAgent) {
        guard let reader = client else { return draft.setState(id, .failed(.uploadInterrupted)) }
        let current = generation
        let previous = uploadQueues[ObjectIdentifier(draft)]
        let preparer = preparer
        draft.setState(id, .queued)
        let task = Task { [weak self] in
            await previous?.value
            guard let self, let file = draft.file(id), file.state == .queued else { return }
            guard !Task.isCancelled, generation == current else { return draft.setState(id, .failed(.uploadInterrupted)) }
            draft.setState(id, .uploading)
            do {
                let prepared = try await preparer.prepare(file.copy, name: file.name, mimeType: file.mimeType)
                // Preparation may convert or re-encode a picture; what goes up is checked again.
                guard PersonalAgentFileRules.accepts(size: prepared.data.count) else { throw PersonalAgentFailure.attachmentLimit }
                try Task.checkCancellation()
                let uploaded = try await reader.upload(prepared, to: agent)
                // A result that outlives its connection is not this draft's to keep.
                guard !Task.isCancelled, generation == current else { throw CancellationError() }
                draft.setState(id, .uploaded(uploaded))
            } catch {
                let failure = error as? PersonalAgentFailure
                if Task.isCancelled || generation != current || error is CancellationError
                    || failure == .accountChanged || failure == .signInRequired || failure == .stopped {
                    draft.setState(id, .failed(.uploadInterrupted))
                } else {
                    let known: Set<PersonalAgentFailure> = [.attachmentLimit, .filePreparation, .uploadFailed, .attachmentsNotAllowed]
                    draft.setState(id, .failed(failure.flatMap { known.contains($0) ? $0 : nil } ?? .uploadFailed))
                }
                if generation == current, let failure, failure == .accountChanged || failure == .signInRequired {
                    accept(failure)
                }
            }
        }
        uploads[id] = task
        uploadQueues[ObjectIdentifier(draft)] = task
    }

    func send() async {
        guard let agent = selected, let reader = client, let state = conversation else { return }
        let current = generation
        let draft = state.draft
        var intended: PersonalAgentDraft.Intended?
        if draft.pending == nil {
            // Files still being copied in are not yet part of what Send would take.
            guard !draft.isSending, !draft.isAddingFiles else { return }
            // Send during uploads sends this text and these files once they are in, as the provider's
            // composer does; the editor stays locked meanwhile, and a file that fails stops the send.
            // The reply target is the open thread's as Send is pressed, kept through the uploads below:
            // closing the dialog or opening another thread meanwhile does not move it.
            let pressed = draft.intended(replyingTo: state.replies.focus?.target)
            intended = pressed
            if pressed.reply != nil, !state.allowsReplies {
                draft.failure = .repliesNotAllowed
                return
            }
            if !pressed.files.isEmpty, !state.allowsAttachments {
                draft.failure = .attachmentsNotAllowed
                return
            }
            if pressed.files.contains(where: { draft.file($0)?.isInProgress == true }) {
                draft.isSending = true
                draft.waitsForUploads = true
                draft.failure = nil
                await draft.uploadsSettled()
                draft.isSending = false
                draft.waitsForUploads = false
                guard current == generation, !Task.isCancelled else { return }
            }
            if pressed.files.contains(where: { draft.file($0)?.uploaded == nil }) {
                draft.failure = .attachmentsIncomplete
                return
            }
        }
        let retry = draft.pending != nil
        guard let submission = draft.prepare(intended) else { return }
        draft.isSending = true
        draft.failure = nil
        var refreshAfterSend = false
        let epoch = state.replies.beginRead()
        do {
            var message = try await reader.send(submission, to: agent)
            // A reply the response does not describe as one still answers the message it was sent to.
            if message.replyToMessageID == nil, let target = submission.replyTarget { message.replyToMessageID = target.messageID }
            // The old account's own draft may finish after navigation. It must
            // never clear the new account's input or append to its conversation.
            draft.accepted(submission.requestID)
            if current == generation {
                state.sentMessages = DotsProjection.merge(state.sentMessages, with: [message], older: false)
                state.replies.noteSent(message, epoch: epoch)
                // A reply shows in its thread; the room stays where the person was reading.
                if submission.replyTarget == nil { state.anchor = message.id }
                reconcileReplies(state)
                refreshAfterSend = selectedID == agent.id
            }
        } catch {
            let failure = error as? PersonalAgentFailure ?? .deliveryUnknown
            if draft.pending?.requestID == submission.requestID { draft.failed(failure, retry: retry) }
            if current == generation { reconcileReplies(state) }
            if current == generation, failure == .accountChanged || failure == .signInRequired { accept(failure) }
        }
        // A slow history backfill must not hold the shared editor's send lock.
        draft.isSending = false
        // A read that showed this request arrived while it was being sent settles it now, from what is
        // already read: nothing is read or sent for it.
        if current == generation, draft.pending?.requestID == submission.requestID { reconcileReplies(state) }
        if refreshAfterSend, current == generation, selectedID == agent.id {
            if state.isLoading { pendingRefresh = true }
            else { await refreshConversation() }
        }
    }

    func download(_ attachment: PersonalAgentAttachment, for identity: PersonalAgentIdentity) async throws -> PersonalAgentDownload {
        guard let agent = selected, agent.id == identity, let client else { throw PersonalAgentFailure.stopped }
        let current = generation
        let value = try await client.download(attachment, for: agent)
        guard current == generation, selectedID == identity else { throw PersonalAgentFailure.stopped }
        return value
    }

    private func detach() -> (any PersonalAgentClient)? {
        generation += 1
        thumbnailStore?.forgetFailures()
        // A local stop: each file is left to retry, and nothing is deleted on the provider.
        uploads.values.forEach { $0.cancel() }
        uploads = [:]
        uploadQueues = [:]
        closeActivity()
        cancelOutputs()
        events?.cancel()
        events = nil
        stopObserving()
        avatarTask?.cancel()
        avatarTask = nil
        pendingRefresh = false
        isLoading = false
        isReconnecting = false
        for state in conversations.values {
            state.isLoading = false
            state.loadID = nil
            // A reply page that answers after this is not the new connection's.
            for thread in state.replies.threads.values {
                thread.isLoadingOlder = false
                thread.olderLoad = nil
                thread.latestLoad = nil
                thread.wantsLatest = false
            }
        }
        let old = client
        client = nil
        return old
    }

    /// Explicitly reconnecting acknowledges a changed login in the same home.
    func forgetReadings() {
        clear()
        sourceKey = nil
    }

    func showUnavailable(_ failure: PersonalAgentFailure) {
        clear()
        self.failure = failure
    }

    private func clear() {
        stopObserving()
        resumedSinceRead = []
        closeActivity()
        cancelOutputs()
        agents = []
        selectedID = nil
        reportShown()
        conversations = [:]
        detailsByAgent = [:]
        avatarData = [:]
        unavailableAvatars = []
        spriteSheets = [:]
        unavailableSprites = []
        thumbnailStore = nil
        hasLoaded = false
        failure = nil
    }

    func accept(_ error: Error) {
        let value = error as? PersonalAgentFailure ?? .network
        if value == .accountChanged || value == .signInRequired {
            stopObserving()
            closeActivity()
            cancelOutputs()
            agents = []
            selectedID = nil
            reportShown()
            conversations = [:]
            detailsByAgent = [:]
            avatarData = [:]
            unavailableAvatars = []
            spriteSheets = [:]
            unavailableSprites = []
            thumbnailStore = nil
        }
        failure = value
    }

    #if DEBUG
    func useFixture(agents: [PersonalAgent], messages: [PersonalAgentMessage]) {
        self.agents = agents
        selectedID = agents.first?.id
        hasLoaded = true
        if let selectedID {
            let state = PersonalAgentConversation()
            state.messages = messages
            state.loaded = true
            state.hasCompleteTail = true
            conversations[selectedID] = state
            reconcileReplies(state)
            if let agent = selected { syncInputRequests(state, agent: agent) }
        }
    }
    #endif
}
