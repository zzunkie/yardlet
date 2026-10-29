import Foundation
import Observation

@MainActor @Observable
final class PersonalAgentConversation {
    let draft: PersonalAgentDraft
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
    @ObservationIgnored var loadID: UUID?
    var failure: PersonalAgentFailure?
    /// Why the last read of earlier messages failed; the conversation stays as it was.
    var olderFailure: PersonalAgentFailure?

    init(draft: PersonalAgentDraft = PersonalAgentDraft()) { self.draft = draft }
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
    @ObservationIgnored private var client: (any PersonalAgentClient)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private let drafts: PersonalAgentDrafts
    private var conversations: [PersonalAgentIdentity: PersonalAgentConversation] = [:]
    private var detailsByAgent: [PersonalAgentIdentity: PersonalAgentDetails] = [:]
    /// Profile pictures read in this window, by dot and picture version; memory only.
    private var avatarData: [AvatarKey: Data] = [:]
    @ObservationIgnored private var unavailableAvatars: Set<AvatarKey> = []
    @ObservationIgnored private var avatarTask: Task<Void, Never>?
    /// Sprite sheets read in this window, by pet; each carries its version. Memory only.
    private var spriteSheets: [String: PersonalAgentSpriteSheet] = [:]
    @ObservationIgnored private var unavailableSprites: Set<String> = []

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

    init(drafts: PersonalAgentDrafts = PersonalAgentDrafts()) { self.drafts = drafts }

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
            if !values.contains(where: { $0.id == selectedID }) {
                selectedID = values.first(where: \.isPrimary)?.id ?? values.first?.id
            }
            // A new connection rereads the profiles, whose signed picture locations may be new.
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
        events?.cancel()
        selectedID = id
        await showSelected()
    }

    private func showSelected() async {
        guard let agent = selected, let client else { return }
        let current = generation
        if conversations[agent.id] == nil {
            conversations[agent.id] = PersonalAgentConversation(draft: drafts.draft(source: draftSourceKey, identity: agent.id))
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
                    // Coalesce updates while a bounded read is already in flight.
                    if self.conversation?.isLoading == true { self.pendingRefresh = true }
                    else { await self.refreshConversation() }
                }
            }
        }
    }

    func refreshConversation(older: Bool = false) async {
        guard let agent = selected, let reader = client, let state = conversations[agent.id], !state.isLoading else { return }
        let before = older ? state.before : nil
        if older && before == nil { return }
        let current = generation
        let loadID = UUID()
        let acceptedBeforeRead = Set(state.sentMessages.map(\.id))
        state.loadID = loadID
        state.isLoading = true
        defer {
            if state.loadID == loadID { state.isLoading = false; state.loadID = nil }
        }
        if older { state.olderFailure = nil } else { state.failure = nil }
        do {
            let page = try await reader.messages(for: agent, before: before)
            guard current == generation, !Task.isCancelled else { return }
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
                    guard current == generation, !Task.isCancelled else { return }
                    incoming = DotsProjection.merge(preceding.messages, with: incoming, older: false)
                    cursor = preceding.before
                    if preceding.messages.isEmpty { break }
                }
            }
            state.messages = older ? DotsProjection.merge(state.messages, with: incoming, older: true) : incoming
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
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            let failure = error as? PersonalAgentFailure ?? .network
            if older { state.olderFailure = failure } else { state.failure = failure }
            if failure == .accountChanged || failure == .signInRequired { accept(failure) }
        }
        state.isLoading = false
        if pendingRefresh, current == generation {
            pendingRefresh = false
            await refreshConversation()
        }
    }

    /// Reads the selected dot's Activity, schedules and computers again, each on its own.
    func refreshDetails() {
        guard let agent = selected, let reader = client else { return }
        let current = generation
        let details = detailsByAgent[agent.id] ?? PersonalAgentDetails()
        detailsByAgent[agent.id] = details
        details.refreshEpoch += 1
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

    func send() async {
        guard let agent = selected, let reader = client, let state = conversation else { return }
        let retry = state.draft.pending != nil
        guard let submission = state.draft.prepare() else { return }
        let current = generation
        let draft = state.draft
        draft.isSending = true
        draft.failure = nil
        var refreshAfterSend = false
        do {
            let message = try await reader.send(submission, to: agent)
            // The old account's own draft may finish after navigation. It must
            // never clear the new account's input or append to its conversation.
            draft.accepted(submission.requestID)
            if current == generation {
                state.sentMessages = DotsProjection.merge(state.sentMessages, with: [message], older: false)
                state.anchor = message.id
                refreshAfterSend = selectedID == agent.id
            }
        } catch {
            let failure = error as? PersonalAgentFailure ?? .deliveryUnknown
            if draft.pending?.requestID == submission.requestID { draft.failed(failure, retry: retry) }
            if current == generation, failure == .accountChanged || failure == .signInRequired { accept(failure) }
        }
        // A slow history backfill must not hold the shared editor's send lock.
        draft.isSending = false
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
        events?.cancel()
        events = nil
        avatarTask?.cancel()
        avatarTask = nil
        pendingRefresh = false
        isLoading = false
        isReconnecting = false
        for state in conversations.values { state.isLoading = false; state.loadID = nil }
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
        agents = []
        selectedID = nil
        conversations = [:]
        detailsByAgent = [:]
        avatarData = [:]
        unavailableAvatars = []
        spriteSheets = [:]
        unavailableSprites = []
        hasLoaded = false
        failure = nil
    }

    private func accept(_ error: Error) {
        let value = error as? PersonalAgentFailure ?? .network
        if value == .accountChanged || value == .signInRequired {
            agents = []
            selectedID = nil
            conversations = [:]
            detailsByAgent = [:]
            avatarData = [:]
            unavailableAvatars = []
            spriteSheets = [:]
            unavailableSprites = []
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
            conversations[selectedID] = state
        }
    }
    #endif
}
