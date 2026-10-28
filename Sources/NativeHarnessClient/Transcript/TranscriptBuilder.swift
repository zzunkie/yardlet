import Foundation

struct TranscriptBuilder: Sendable {
    private(set) var entries: [TranscriptEntry] = []
    private var currentAssistantEntryID: UUID?
    private var currentReasoningEntryID: UUID?
    /// The answer and thinking entries streamed since the last completed message, in order. A
    /// new card between deltas ends a streamed entry and the next delta starts another; the
    /// completed message then takes the first of them and the rest go (`completeStreamed`).
    private var streamedAssistantIDs: [UUID] = []
    private var streamedReasoningIDs: [UUID] = []
    private var entryLimit = 500

    /// The most entries a builder keeps. A Claude conversation read from its saved transcript
    /// holds as many as the reads covered (`ClaudeTranscriptTail`), which only a transcript of
    /// gigabytes would bring near this.
    static let maximumEntryLimit = 200_000

    init(entries: [TranscriptEntry] = [], limit: Int = 500) {
        entryLimit = min(max(1, limit), Self.maximumEntryLimit)
        self.entries = Array(entries.suffix(entryLimit)).compactMap { entry in
            var restored = entry
            switch restored.content {
            case let .assistant(text, _):
                restored.content = .assistant(text: text, isStreaming: false)
            case let .reasoning(text, _):
                restored.content = .reasoning(text: text, isStreaming: false)
            case .activity(_, .running), .permission(_, .pending):
                // A detached snapshot cannot establish either outcome or answerability. Omit the
                // transient card instead of displaying a false completed/denied state.
                return nil
            case let .compaction(compaction) where compaction.phase == .started:
                return nil
            default:
                break
            }
            return restored
        }
    }

    /// - Parameter joinsRunningTurn: the provider read the message into the turn that was running.
    /// - Parameter origin: someone other than the person sent it (`TranscriptRequestOrigin`).
    @discardableResult
    mutating func appendUser(
        _ text: String, images: [TranscriptImageAttachment] = [], joinsRunningTurn: Bool = false,
        origin: TranscriptRequestOrigin? = nil
    ) -> UUID {
        finishStreamingBlocks()
        let entry = TranscriptEntry(content: .user(text: text, images: images.isEmpty ? nil : images),
                                    joinsRunningTurn: joinsRunningTurn ? true : nil, origin: origin)
        entries.append(entry)
        trimIfNeeded()
        return entry.id
    }

    /// Earlier history read from the provider's saved record, put in place of everything before
    /// `id`: the entries a shorter read began with, which the longer one holds too. They are settled
    /// as a restored snapshot is, and the limit keeps the newest entries, so what streams after `id`
    /// is never pushed out. Nothing changes when `id` is not here.
    mutating func replaceEntries(before id: UUID, with earlier: [TranscriptEntry]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        replaceEntries(upTo: index, with: earlier)
    }

    /// Earlier history read from the provider's saved record put in place of everything through `id`:
    /// a part of a turn a shorter read began inside, which the longer read holds whole. What streams
    /// after `id` stays. Nothing changes when `id` is not here.
    mutating func replaceEntries(through id: UUID, with earlier: [TranscriptEntry]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        replaceEntries(upTo: index + 1, with: earlier)
    }

    private mutating func replaceEntries(upTo index: Int, with earlier: [TranscriptEntry]) {
        let removedIDs = Set(entries[..<index].map(\.id))
        let room = max(0, entryLimit - (entries.count - index))
        let settled = TranscriptBuilder(entries: earlier, limit: entryLimit).entries
        entries = Array(settled.suffix(room)) + entries[index...]
        if let currentAssistantEntryID, removedIDs.contains(currentAssistantEntryID) {
            self.currentAssistantEntryID = nil
        }
        if let currentReasoningEntryID, removedIDs.contains(currentReasoningEntryID) {
            self.currentReasoningEntryID = nil
        }
    }

    /// Keeps at least `limit` entries from now on: earlier history read in grows what the builder holds.
    mutating func raiseLimit(to limit: Int) {
        entryLimit = max(entryLimit, min(limit, Self.maximumEntryLimit))
    }

    /// A request whose text is settled after it is shown: a bash-mode command gets its output.
    mutating func replaceUserText(of id: UUID, with text: String) {
        guard let index = entries.lastIndex(where: { $0.id == id }),
              case let .user(_, images) = entries[index].content else { return }
        entries[index].content = .user(text: text, images: images)
    }

    /// The request of a turn the provider started itself, read after the turn opened: it takes
    /// `request`'s words, images and origin in place, so the turn keeps its place and identity.
    mutating func settleRequest(of id: UUID, as request: TranscriptEntry) {
        guard let index = entries.lastIndex(where: { $0.id == id }), case .user = entries[index].content,
              case .user = request.content else { return }
        entries[index].content = request.content
        entries[index].origin = request.origin
    }

    mutating func apply(_ payload: HarnessEventPayload) {
        switch payload {
        case let .assistantDelta(delta):
            appendAssistantDelta(delta)

        case let .assistantMessageCompleted(text):
            completeAssistant(with: text)

        case let .reasoningDelta(delta):
            appendReasoningDelta(delta)

        case let .reasoningCompleted(text):
            completeReasoning(with: text)

        case let .progressUpdateCompleted(text):
            completeReasoning(with: text, isProgressUpdate: true)

        case let .activityStarted(activity), let .activityUpdated(activity):
            // A card already shown changes where it is: a background task's progress, which can
            // arrive while the answer streams, does not cut the answer in two. Nor does a
            // subagent's own task, which is no card in the session (`isSubagentWork`).
            if !showsActivity(activity.id), activity.subtask?.isSubagentWork != true { finishStreamingBlocks() }
            upsertActivity(activity, state: .running)

        case let .activityCompleted(activity):
            if !showsActivity(activity.id), activity.subtask?.isSubagentWork != true { finishStreamingBlocks() }
            let state: TranscriptActivityState = switch activity.outcome {
            case .failed: .failed
            case .stopped: .stopped
            case nil: .completed
            }
            upsertActivity(activity, state: state)

        case let .permissionRequested(request):
            finishStreamingBlocks()
            entries.append(
                TranscriptEntry(content: .permission(request, state: .pending))
            )

        case let .permissionExpired(requestID):
            for index in entries.indices {
                if case let .permission(request, .pending) = entries[index].content, request.id == requestID {
                    entries[index].content = .permission(request, state: .expired)
                }
            }

        case let .planUpdated(plan):
            finishStreamingBlocks()
            upsertPlan(plan)

        case .turnCompleted:
            finishStreamingBlocks()
            forgetStreamedEntries()
            completeRunningActivities(includingBackground: false)
            expirePendingPermissions()
            // The turn went on past a compaction whose end the provider did not announce.
            finishRunningCompaction(as: .completed)

        case let .error(message, recoverable, transient):
            finishStreamingBlocks()
            forgetStreamedEntries()
            completeRunningActivities()
            finishRunningCompaction(as: .failed)
            entries.append(
                TranscriptEntry(content: .error(message: message, recoverable: recoverable, transient: transient))
            )

        case let .usageLimitReached(limit):
            finishStreamingBlocks()
            forgetStreamedEntries()
            completeRunningActivities()
            finishRunningCompaction(as: .failed)
            upsertUsageLimit(limit)

        case let .contextCompaction(compaction):
            finishStreamingBlocks()
            applyCompaction(compaction)

        case .sessionStarted, .sessionStatusChanged, .usageUpdated, .providerCapabilitiesChanged,
             .rateLimitUpdated, .providerRetrying, .followUpDelivery, .nextMessageSuggestion, .providerStartedTurn,
             .turnCutOff:
            // A read follow-up's bubble is added by its owner, which holds the message itself, as is
            // the request of a turn the provider started itself, which its owner reads. A suggested
            // next message belongs to the composer, never the conversation.
            break
        }
        trimIfNeeded()
    }

    mutating func endRuntime() {
        finishStreamingBlocks()
        forgetStreamedEntries()
        completeRunningActivities()
        expirePendingPermissions()
        finishRunningCompaction(as: .failed)
    }

    /// One card per stopped turn. The provider can name the window and its reset in a report
    /// that arrives after its own message about the limit, so a later report fills in the card
    /// the turn already shows instead of adding a second one.
    private mutating func upsertUsageLimit(_ limit: HarnessRateLimit) {
        guard let last = entries.indices.last,
              case let .usageLimit(existing) = entries[last].content else {
            entries.append(TranscriptEntry(content: .usageLimit(limit)))
            return
        }
        var merged = limit
        merged.window = limit.window ?? existing.window
        merged.model = limit.model ?? existing.model
        merged.resetsAt = limit.resetsAt ?? existing.resetsAt
        merged.usedFraction = limit.usedFraction ?? existing.usedFraction
        merged.message = limit.message ?? existing.message
        if merged.windows.isEmpty { merged.windows = existing.windows }
        entries[last].content = .usageLimit(merged)
    }

    /// A compaction shows as one marker that starts running and settles. The provider repeats its
    /// start while it works and reports the end both as a status and as a boundary carrying the
    /// token counts, in either order, so those fill in the same marker.
    private mutating func applyCompaction(_ update: HarnessContextCompaction) {
        let index = entries.lastIndex { entry in
            if case .compaction = entry.content { return true }
            return false
        }
        guard let index, case let .compaction(existing) = entries[index].content else {
            entries.append(TranscriptEntry(content: .compaction(update)))
            return
        }
        let isSameTurn = !entries[(index + 1)...].contains { entry in
            if case .user = entry.content { return true }
            return false
        }
        switch update.phase {
        case .started:
            guard existing.phase != .started else { return }
            entries.append(TranscriptEntry(content: .compaction(update)))
        case .completed, .failed:
            guard existing.phase == .started || (isSameTurn && existing.phase == update.phase) else {
                entries.append(TranscriptEntry(content: .compaction(update)))
                return
            }
            var settled = existing
            settled.phase = update.phase
            settled.tokensBefore = update.tokensBefore ?? existing.tokensBefore
            settled.tokensAfter = update.tokensAfter ?? existing.tokensAfter
            settled.message = update.message ?? existing.message
            entries[index].content = .compaction(settled)
        }
    }

    private mutating func finishRunningCompaction(as phase: HarnessContextCompaction.Phase) {
        for index in entries.indices {
            guard case var .compaction(compaction) = entries[index].content,
                  compaction.phase == .started else { continue }
            compaction.phase = phase
            entries[index].content = .compaction(compaction)
        }
    }

    private mutating func expirePendingPermissions() {
        for index in entries.indices {
            if case let .permission(request, .pending) = entries[index].content {
                entries[index].content = .permission(request, state: .expired)
            }
        }
    }

    mutating func resolvePermission(id: String, decision: PermissionDecision) {
        guard let index = entries.lastIndex(where: { entry in
            guard case let .permission(request, state) = entry.content else { return false }
            return request.id == id && state == .pending
        }) else { return }
        guard case let .permission(request, _) = entries[index].content else { return }
        entries[index].content = .permission(
            request,
            state: decision == .allow ? .allowed : .denied
        )
    }

    private mutating func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        finishReasoningIfNeeded()
        if let currentAssistantEntryID,
           let index = entries.lastIndex(where: { $0.id == currentAssistantEntryID }),
           case let .assistant(text, _) = entries[index].content {
            entries[index].content = .assistant(text: text + delta, isStreaming: true)
        } else {
            let entry = TranscriptEntry(content: .assistant(text: delta, isStreaming: true))
            currentAssistantEntryID = entry.id
            streamedAssistantIDs.append(entry.id)
            entries.append(entry)
        }
    }

    private mutating func completeAssistant(with text: String) {
        finishReasoningIfNeeded()
        if completeStreamed(streamedAssistantIDs, with: text, as: { .assistant(text: $0, isStreaming: false) }) != nil {
            // The streamed entries were this message's.
        } else if let currentAssistantEntryID,
           let index = entries.lastIndex(where: { $0.id == currentAssistantEntryID }) {
            entries[index].content = .assistant(text: text, isStreaming: false)
        } else if !text.isEmpty {
            entries.append(
                TranscriptEntry(content: .assistant(text: text, isStreaming: false))
            )
        }
        currentAssistantEntryID = nil
        streamedAssistantIDs.removeAll()
    }

    /// The completed message in place of what streamed of it: the entries streamed since the last
    /// completed message whose texts, joined, begin the message (a card shown between deltas split
    /// it). The first of them takes the whole message and the others go, so the answer shows once
    /// and whole where it began. Entries before them that do not begin it are another message's
    /// (one that never completed) and stay. The entry that took the message, or nil when nothing
    /// streamed begins it.
    private mutating func completeStreamed(
        _ ids: [UUID], with text: String, as content: (String) -> TranscriptEntryContent
    ) -> UUID? {
        let streamed: [(id: UUID, text: String)] = ids.compactMap { id in
            guard let index = entries.lastIndex(where: { $0.id == id }) else { return nil }
            switch entries[index].content {
            case let .assistant(text, _), let .reasoning(text, _): return (id, text)
            default: return nil
            }
        }
        for start in streamed.indices {
            let part = streamed[start...].map(\.text).joined()
            guard !part.isEmpty, text.unicodeScalars.starts(with: part.unicodeScalars) else { continue }
            let first = streamed[start].id
            let rest = Set(streamed[(start + 1)...].map(\.id))
            if let index = entries.lastIndex(where: { $0.id == first }) {
                entries[index].content = content(text)
            }
            entries.removeAll { rest.contains($0.id) }
            return first
        }
        return nil
    }

    private mutating func forgetStreamedEntries() {
        streamedAssistantIDs.removeAll()
        streamedReasoningIDs.removeAll()
    }

    /// A card for this activity is already in the conversation.
    private func showsActivity(_ id: String) -> Bool {
        entries.contains { entry in
            guard case let .activity(existing, _) = entry.content else { return false }
            return existing.id == id
        }
    }

    private mutating func finishStreamingBlocks() {
        finishAssistantIfNeeded()
        finishReasoningIfNeeded()
    }

    /// Reasoning is its own block. A thought stream must not merge into the answer, and the
    /// answer must not reopen a thought the provider already finished.
    private mutating func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        finishAssistantIfNeeded()
        if let currentReasoningEntryID,
           let index = entries.lastIndex(where: { $0.id == currentReasoningEntryID }),
           case let .reasoning(text, _) = entries[index].content {
            entries[index].content = .reasoning(text: text + delta, isStreaming: true)
        } else {
            let entry = TranscriptEntry(content: .reasoning(text: delta, isStreaming: true))
            currentReasoningEntryID = entry.id
            streamedReasoningIDs.append(entry.id)
            entries.append(entry)
        }
    }

    /// - Parameter isProgressUpdate: the block is what the model wrote between tool calls, which
    ///   streamed as thinking (`TranscriptEntry.isProgressUpdate`).
    private mutating func completeReasoning(with text: String, isProgressUpdate: Bool = false) {
        finishAssistantIfNeeded()
        var completed = completeStreamed(streamedReasoningIDs, with: text, as: { .reasoning(text: $0, isStreaming: false) })
        if completed != nil {
            // The streamed thinking was this block's.
        } else if let currentReasoningEntryID,
           let index = entries.lastIndex(where: { $0.id == currentReasoningEntryID }) {
            entries[index].content = .reasoning(text: text, isStreaming: false)
            completed = currentReasoningEntryID
        } else if !text.isEmpty {
            let entry = TranscriptEntry(content: .reasoning(text: text, isStreaming: false))
            entries.append(entry)
            completed = entry.id
        }
        if isProgressUpdate, let completed, let index = entries.lastIndex(where: { $0.id == completed }) {
            entries[index].isProgressUpdate = true
        }
        currentReasoningEntryID = nil
        streamedReasoningIDs.removeAll()
    }

    private mutating func finishReasoningIfNeeded() {
        guard let currentReasoningEntryID,
              let index = entries.lastIndex(where: { $0.id == currentReasoningEntryID }),
              case let .reasoning(text, _) = entries[index].content else {
            self.currentReasoningEntryID = nil
            return
        }
        entries[index].content = .reasoning(text: text, isStreaming: false)
        self.currentReasoningEntryID = nil
    }

    private mutating func finishAssistantIfNeeded() {
        guard let currentAssistantEntryID,
              let index = entries.lastIndex(where: { $0.id == currentAssistantEntryID }),
              case let .assistant(text, _) = entries[index].content else {
            self.currentAssistantEntryID = nil
            return
        }
        entries[index].content = .assistant(text: text, isStreaming: false)
        self.currentAssistantEntryID = nil
    }

    private mutating func completeRunningActivities(includingBackground: Bool = true) {
        for index in entries.indices {
            guard case let .activity(activity, .running) = entries[index].content else { continue }
            guard includingBackground || activity.isBackground != true else { continue }
            entries[index].content = .activity(activity, state: .stopped)
        }
    }

    private mutating func upsertActivity(
        _ activity: HarnessActivity,
        state: TranscriptActivityState
    ) {
        if let index = entries.lastIndex(where: { entry in
            guard case let .activity(existing, _) = entry.content else { return false }
            return existing.id == activity.id
        }) {
            guard case let .activity(existing, _) = entries[index].content else { return }
            entries[index].content = .activity(
                Self.merging(existing, with: activity),
                state: state
            )
        } else {
            entries.append(TranscriptEntry(content: .activity(activity, state: state)))
        }
    }

    /// A tool update carries only what changed. A completion that reports output must not erase
    /// the input the start event established, and vice versa.
    static func merging(
        _ existing: HarnessActivity,
        with update: HarnessActivity
    ) -> HarnessActivity {
        HarnessActivity(
            id: update.id,
            kind: update.kind,
            title: update.title,
            detail: update.detail ?? existing.detail,
            outcome: update.outcome,
            input: update.input ?? existing.input,
            output: update.output ?? existing.output,
            diff: update.diff ?? existing.diff,
            isBackground: update.isBackground ?? existing.isBackground,
            subtask: update.subtask ?? existing.subtask,
            answeredQuestions: update.answeredQuestions ?? existing.answeredQuestions,
            images: update.images ?? existing.images
        )
    }

    private mutating func upsertPlan(_ plan: String) {
        let latestUserIndex = entries.lastIndex { entry in
            if case .user = entry.content { return true }
            return false
        }
        if let index = entries.lastIndex(where: { entry in
            if case .plan = entry.content { return true }
            return false
        }), latestUserIndex == nil || index > latestUserIndex! {
            entries[index].content = .plan(plan)
        } else {
            entries.append(TranscriptEntry(content: .plan(plan)))
        }
    }

    private mutating func trimIfNeeded() {
        let limit = entryLimit
        guard entries.count > limit else { return }
        let overflow = entries.count - limit
        let removedIDs = Set(entries.prefix(overflow).map(\.id))
        entries.removeFirst(overflow)
        if let currentAssistantEntryID, removedIDs.contains(currentAssistantEntryID) {
            self.currentAssistantEntryID = nil
        }
        if let currentReasoningEntryID, removedIDs.contains(currentReasoningEntryID) {
            self.currentReasoningEntryID = nil
        }
    }
}
