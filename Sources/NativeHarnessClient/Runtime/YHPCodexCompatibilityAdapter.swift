import Foundation

/// Codex product adapter over the typed `yardlet.codex` YHP extension surface.
///
/// The generic compatibility adapter owns canonical lifecycle projection. This wrapper adds the
/// native Codex product protocols without forwarding around YHP, so AppModel keeps its existing
/// capability-driven casts while every provider operation crosses a typed request/event boundary.
actor YHPCodexCompatibilityAdapter:
    VersionedHarnessAdapter,
    CodexCapabilityProviding,
    CodexPresentationProviding,
    CodexComposerProviding,
    CodexConversationEditing,
    CodexTurnRecovering,
    HarnessInterruptedTurnContinuing,
    CodexPendingServerRequestValidating,
    CodexThreadReading,
    WrappedAdapterLaunchForwarding,
    HarnessMCPServerStatusReading
{
    nonisolated let kind = HarnessKind.codex
    nonisolated let protocolManifest: HarnessAdapterManifest

    private let core: YHPCompatibilityAdapter
    /// The wrapped adapter still owns the process and the `thread/start` request it sends, so a
    /// project's extra roots, the Yardlet MCP server, and the provider's instruction-source answer
    /// cross this wrapper instead of stopping at it.
    nonisolated let launchFacets: WrappedAdapterLaunchFacets
    private let payloadCodec = HarnessProtocolPayloadCodec()
    private var nextClientTurnSequence: UInt64 = 0
    private var activeTurnIDs: [UUID: String] = [:]
    private var presentationBySessionID: [UUID: CodexTaskState] = [:]
    private var answerableRequestsBySessionID: [
        UUID: [String: HarnessProtocolCodexServerRequest]
    ] = [:]
    private var presentationContinuations: [
        UUID: AsyncStream<CodexTaskState>.Continuation
    ] = [:]
    private var presentationTasks: [UUID: Task<Void, Never>] = [:]
    /// Whether the adapter sends live presentation as revisioned patches when asked. Each
    /// session's chain is the presentation at its newest applied revision; a patch against any
    /// other revision is dropped and a complete snapshot read instead.
    private let acceptsPresentationPatches: Bool
    private var presentationChains: [UUID: CodexYHPPresentationChain] = [:]
    private var presentationResyncs: Set<UUID> = []
    /// Sessions whose published presentation equals their chain's.
    private var publishedChainSessionIDs: Set<UUID> = []
    /// Live patches applied and complete snapshots asked for after a gap, for measurement.
    private(set) var appliedPresentationPatchCount = 0
    private(set) var presentationResyncCount = 0

    /// The thread's MCP servers (`mcpServerStatus/list`) have no YHP operation; the read goes to
    /// the wrapped adapter.
    private let mcpStatusReading: (any HarnessMCPServerStatusReading)?
    /// Nor have the thread's background terminals (`thread/backgroundTerminals/list`, App Server 0.163): the session
    /// rail lists them and the memory saver keeps a thread that has one.
    private let backgroundTerminalControl: (any CodexBackgroundTerminalControlling)?

    init(adapter: any HarnessAdapter, manifest: HarnessAdapterManifest) {
        precondition(adapter.kind == .codex && manifest.harness == .codex)
        protocolManifest = manifest
        acceptsPresentationPatches = manifest.supports(.codexPresentationPatches)
        launchFacets = WrappedAdapterLaunchFacets(wrapping: adapter)
        mcpStatusReading = adapter as? any HarnessMCPServerStatusReading
        backgroundTerminalControl = adapter as? any CodexBackgroundTerminalControlling
        core = YHPCompatibilityAdapter(
            adapter: adapter,
            manifest: manifest,
            canceledTurnProjection: .complete
        )
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        try await core.probeRuntime()
    }

    func mcpServers(for session: HarnessSessionHandle) async throws -> [HarnessMCPServerStatus] {
        guard let mcpStatusReading else {
            throw HarnessAdapterError.capabilityUnavailable("MCP server status is unavailable")
        }
        return try await mcpStatusReading.mcpServers(for: session)
    }

    func reportedMCPServers(for localSessionID: UUID) async -> [HarnessMCPServerStatus]? {
        await mcpStatusReading?.reportedMCPServers(for: localSessionID) ?? nil
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let handle = try await core.createSession(request)
        _ = try await readPresentation(for: handle, refresh: false, startingLivePatches: true)
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        let handle = try await core.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: localSessionID,
            workspaceURL: workspaceURL
        )
        _ = try await readPresentation(for: handle, refresh: false, startingLivePatches: true)
        return handle
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await submit(
            CodexComposerDraft(inputs: [.text(prompt)]),
            submission: .start,
            to: session
        )
    }

    func submit(
        _ draft: CodexComposerDraft,
        submission: CodexTurnSubmission,
        to session: HarnessSessionHandle
    ) async throws {
        guard !draft.isEmpty else { return }
        let kind: HarnessProtocolCodexSubmissionKind
        let expectedTurnID: String?
        switch submission {
        case .start:
            kind = .start
            expectedTurnID = nil
        case let .steer(expected):
            kind = .steer
            expectedTurnID = expected
        }
        let state: HarnessProtocolCodexComposerState = try await core.perform(
            .codexComposerSubmit,
            params: HarnessProtocolCodexComposerSubmitParams(
                localSessionID: session.localSessionID,
                clientTurnID: nextClientTurnID(),
                inputs: draft.inputs.map(\.jsonValue),
                submission: kind,
                expectedTurnID: expectedTurnID
            )
        )
        activeTurnIDs[session.localSessionID] = state.activeTurnID
    }

    func activeTurnID(for session: HarnessSessionHandle) -> String? {
        activeTurnIDs[session.localSessionID]
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        try await core.interrupt(session)
        activeTurnIDs.removeValue(forKey: session.localSessionID)
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        try await core.respond(
            to: permissionRequestID,
            decision: decision,
            in: session
        )
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        await core.events(for: session)
    }

    func presentationState(for session: HarnessSessionHandle) throws -> CodexTaskState {
        presentationBySessionID[session.localSessionID] ?? .empty
    }

    func refreshPresentationState(
        for session: HarnessSessionHandle
    ) async throws -> CodexTaskState {
        try await readPresentation(for: session, refresh: true)
    }

    func loadTurns(
        for session: HarnessSessionHandle,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexTurnPage {
        let page: HarnessProtocolCodexTurnPage = try await core.perform(
            .codexTurnsLoad,
            params: HarnessProtocolCodexTurnsLoadParams(
                localSessionID: session.localSessionID,
                cursor: cursor,
                limit: limit
            )
        )
        _ = try await readPresentation(for: session, refresh: false)
        return CodexTurnPage(
            turns: page.turns.map(CodexYHPProjection.turn),
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    func loadItems(
        for session: HarnessSessionHandle,
        turnID: String?,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexItemPage {
        let page: HarnessProtocolCodexItemPage = try await core.perform(
            .codexItemsLoad,
            params: HarnessProtocolCodexItemsLoadParams(
                localSessionID: session.localSessionID,
                turnID: turnID,
                cursor: cursor,
                limit: limit
            )
        )
        _ = try await readPresentation(for: session, refresh: false)
        return CodexItemPage(
            entries: page.entries.map { entry in
                CodexItemPageEntry(
                    turnID: entry.turnID,
                    item: CodexYHPProjection.item(entry.item)
                )
            },
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    func presentationStates(
        for session: HarnessSessionHandle
    ) async throws -> AsyncStream<CodexTaskState> {
        let localSessionID = session.localSessionID
        // Preserve the latest-snapshot policy through the product's YHP boundary too.
        // Protocol events remain lossless; only superseded UI snapshots can be skipped.
        let stream = AsyncStream<CodexTaskState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.yield(presentationBySessionID[localSessionID] ?? .empty)
        presentationContinuations[localSessionID]?.finish()
        presentationContinuations[localSessionID] = stream.continuation

        presentationTasks.removeValue(forKey: localSessionID)?.cancel()
        // The replay starts from the oldest event the core kept, so the chain starts over too.
        presentationChains.removeValue(forKey: localSessionID)
        publishedChainSessionIDs.remove(localSessionID)
        let protocolEvents = await core.protocolEvents(for: localSessionID)
        presentationTasks[localSessionID] = Task { [weak self] in
            for await event in protocolEvents {
                guard !Task.isCancelled else { break }
                await self?.acceptProtocolEvent(event)
            }
            guard !Task.isCancelled else { return }
            await self?.endProtocolEvents(for: localSessionID)
        }
        return stream.stream
    }

    /// The session's events end with its provider connection, which ends any turn with it, as the
    /// wrapped adapter forgets it too.
    private func endProtocolEvents(for localSessionID: UUID) {
        activeTurnIDs.removeValue(forKey: localSessionID)
    }

    func respond(
        to serverRequestID: String,
        response: CodexServerRequestResponse,
        in session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexServerRequestRespond,
            params: HarnessProtocolCodexServerRequestRespondParams(
                localSessionID: session.localSessionID,
                requestID: serverRequestID,
                response: CodexYHPProjection.serverResponse(response)
            )
        )
        _ = try await readPresentation(for: session, refresh: false)
    }

    func modelCatalog(for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        try await core.perform(.codexModelsRead, params: HarnessProtocolSessionReference(localSessionID: session.localSessionID))
    }

    func selectModel(_ selection: CodexModelSelection, for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        try await core.perform(.codexModelSet, params: HarnessProtocolCodexModelSetParams(localSessionID: session.localSessionID, selection: selection))
    }

    func collaborationModes() async throws -> [CodexCollaborationPreset] {
        let catalog: HarnessProtocolCodexControlsCatalog = try await core.perform(
            .codexControlsRead,
            params: HarnessProtocolCodexControlsReadParams(localSessionID: try sessionID())
        )
        return catalog.collaborationModes.map(CodexYHPProjection.collaborationMode)
    }

    func accountRateLimits() async throws -> CodexAccountRateLimits {
        try await core.perform(.codexAccountRateLimitsRead, params: HarnessProtocolEmptyParams())
    }

    func skills(in workspaceURL: URL) async throws -> [CodexSkillSummary] {
        let catalog: HarnessProtocolCodexSkillsCatalog = try await core.perform(
            .codexSkillsRead,
            params: HarnessProtocolCodexWorkspaceParams(
                workspacePath: workspaceURL.standardizedFileURL.path(percentEncoded: false)
            )
        )
        return catalog.skills.map { skill in
            CodexSkillSummary(
                name: skill.name,
                displayName: skill.displayName,
                description: skill.description,
                enabled: skill.enabled,
                scope: skill.scope,
                path: skill.path
            )
        }
    }

    func plugins(in workspaceURL: URL) async throws -> [CodexPluginSummary] {
        let catalog: HarnessProtocolCodexPluginsCatalog = try await core.perform(
            .codexPluginsRead,
            params: HarnessProtocolCodexWorkspaceParams(
                workspacePath: workspaceURL.standardizedFileURL.path(percentEncoded: false)
            )
        )
        return catalog.plugins.map { plugin in
            CodexPluginSummary(
                id: plugin.id,
                name: plugin.name,
                displayName: plugin.displayName,
                description: plugin.description,
                installed: plugin.installed,
                enabled: plugin.enabled,
                availability: plugin.availability,
                marketplace: plugin.marketplace
            )
        }
    }

    func readThreadPresentation(threadID: String, newestTurns: Int64?) async throws -> CodexTaskState {
        let result: HarnessProtocolCodexThreadReadResult = try await core.perform(
            .codexThreadRead,
            params: HarnessProtocolCodexThreadReadParams(threadID: threadID, newestTurns: newestTurns)
        )
        return CodexTaskState(thread: CodexYHPProjection.thread(result.thread))
    }

    func readThreadTurns(threadID: String, cursor: String?, limit: Int64) async throws -> CodexTurnPage {
        let page: HarnessProtocolCodexTurnPage = try await core.perform(
            .codexThreadTurnsRead,
            params: HarnessProtocolCodexThreadTurnsReadParams(threadID: threadID, cursor: cursor, limit: limit)
        )
        return CodexTurnPage(
            turns: page.turns.map(CodexYHPProjection.turn),
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    func recentThreads(in workspaceURL: URL) async throws -> [CodexThreadSummary] {
        try await recentThreadsPage(in: workspaceURL, cursor: nil, limit: 30).threads
    }

    func recentThreadsPage(
        in workspaceURL: URL,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexRecentThreadsPage {
        let page: HarnessProtocolCodexRecentThreadsPage = try await core.perform(
            .codexHistoryRecent,
            params: HarnessProtocolCodexHistoryParams(
                workspacePath: workspaceURL.standardizedFileURL.path(percentEncoded: false),
                cursor: cursor,
                limit: limit
            )
        )
        return CodexRecentThreadsPage(
            threads: page.threads.map(CodexYHPProjection.threadSummary),
            nextCursor: page.nextCursor
        )
    }

    func interactiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        let page: HarnessProtocolCodexRecentThreadsPage = try await core.perform(
            .codexHistoryInteractive,
            params: HarnessProtocolCodexHistoryPageParams(cursor: cursor, limit: limit)
        )
        return CodexRecentThreadsPage(
            threads: page.threads.map(CodexYHPProjection.threadSummary),
            nextCursor: page.nextCursor
        )
    }

    func archivedInteractiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        let page: HarnessProtocolCodexRecentThreadsPage = try await core.perform(
            .codexHistoryInteractive,
            params: HarnessProtocolCodexHistoryPageParams(cursor: cursor, limit: limit, archived: true)
        )
        return CodexRecentThreadsPage(
            threads: page.threads.map(CodexYHPProjection.threadSummary),
            nextCursor: page.nextCursor
        )
    }

    func searchThreads(
        in workspaceURL: URL,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchPage {
        let page: HarnessProtocolCodexThreadSearchPage = try await core.perform(
            .codexHistorySearch,
            params: HarnessProtocolCodexHistorySearchParams(
                workspacePath: workspaceURL.standardizedFileURL.path(percentEncoded: false),
                query: searchTerm,
                cursor: cursor,
                limit: limit
            )
        )
        return CodexThreadSearchPage(
            matches: page.matches.map { match in
                CodexThreadSearchMatch(
                    thread: CodexYHPProjection.threadSummary(match.thread),
                    snippet: match.snippet
                )
            },
            nextCursor: page.nextCursor
        )
    }

    func searchOccurrences(
        threadID: String,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchOccurrencesPage {
        let page: HarnessProtocolCodexSearchOccurrencesPage = try await core.perform(
            .codexHistoryOccurrences,
            params: HarnessProtocolCodexHistoryOccurrencesParams(
                providerSessionID: threadID,
                query: searchTerm,
                cursor: cursor,
                limit: limit
            )
        )
        return CodexThreadSearchOccurrencesPage(
            occurrences: page.occurrences.map { occurrence in
                CodexThreadSearchOccurrence(
                    turnID: occurrence.turnID,
                    itemID: occurrence.itemID,
                    snippet: occurrence.snippet,
                    snippetMatchRange: occurrence.snippetMatchRange,
                    turnCursor: occurrence.turnCursor
                )
            },
            nextCursor: page.nextCursor
        )
    }

    func setThreadName(_ name: String, for session: HarnessSessionHandle) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexThreadRename,
            params: HarnessProtocolCodexThreadRenameParams(
                localSessionID: session.localSessionID,
                name: name
            )
        )
    }

    func archiveThread(_ session: HarnessSessionHandle) async throws {
        try await performSessionAction(.codexThreadArchive, session: session)
    }

    func unarchiveThread(threadID: String) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexThreadUnarchive,
            params: HarnessProtocolCodexThreadReference(providerSessionID: threadID)
        )
    }

    func deleteThread(_ session: HarnessSessionHandle) async throws {
        try await performSessionAction(.codexThreadDelete, session: session)
    }

    func selectCollaborationMode(
        _ preset: CodexCollaborationPreset?,
        for session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexCollaborationSet,
            params: HarnessProtocolCodexCollaborationSetParams(
                localSessionID: session.localSessionID,
                modeID: preset?.id
            )
        )
    }

    func selectRunLocation(
        _ location: CodexRunLocation,
        for session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexRunLocationSet,
            params: HarnessProtocolCodexRunLocationSetParams(
                localSessionID: session.localSessionID,
                runLocationID: location.rawValue
            )
        )
    }

    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID
    ) async throws -> HarnessSessionHandle {
        try await fork(session, newLocalSessionID: newLocalSessionID, throughTurnID: nil)
    }

    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID,
        throughTurnID: String?
    ) async throws -> HarnessSessionHandle {
        let descriptor: HarnessProtocolSessionDescriptor = try await core.perform(
            .codexSessionFork,
            params: HarnessProtocolCodexForkParams(
                localSessionID: session.localSessionID,
                newLocalSessionID: newLocalSessionID,
                throughTurnID: throughTurnID
            )
        )
        let forked = await core.attachReturnedSession(descriptor)
        _ = try await readPresentation(for: forked, refresh: false, startingLivePatches: true)
        return forked
    }

    func prepareConversationEdit(_ edit: ConversationEditState, in session: HarnessSessionHandle) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(.codexConversationEdit,
            params: HarnessProtocolCodexConversationEditParams(localSessionID: session.localSessionID, edit: edit))
        _ = try await readPresentation(for: session, refresh: false)
    }

    func retryFailedTurn(_ turnID: String, in session: HarnessSessionHandle) async throws {
        let state: HarnessProtocolCodexComposerState = try await core.perform(.codexTurnRetry,
            params: HarnessProtocolCodexTurnRetryParams(localSessionID: session.localSessionID, expectedTurnID: turnID))
        activeTurnIDs[session.localSessionID] = state.activeTurnID
    }

    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool {
        let result: HarnessProtocolCodexTurnContinueResult = try await core.perform(.codexTurnContinue,
            params: HarnessProtocolCodexTurnContinueParams(localSessionID: session.localSessionID, cut: cut))
        activeTurnIDs[session.localSessionID] = result.activeTurnID
        return result.started
    }

    func compactConversation(in session: HarnessSessionHandle) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(.codexCompactStart,
            params: HarnessProtocolCodexCompactParams(localSessionID: session.localSessionID))
    }

    func startWorkingTreeReview(in session: HarnessSessionHandle) async throws {
        try await startReview(.uncommittedChanges, in: session)
    }

    func startReview(_ target: CodexReviewTarget, in session: HarnessSessionHandle) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            .codexReviewStart,
            params: HarnessProtocolCodexReviewStartParams(
                localSessionID: session.localSessionID,
                clientTurnID: nextClientTurnID(), target: target
            )
        )
    }

    func answerablePendingServerRequestIDs(
        _ requests: [CodexPendingServerRequest],
        for session: HarnessSessionHandle
    ) -> Set<String> {
        let live = answerableRequestsBySessionID[session.localSessionID] ?? [:]
        return Set(requests.compactMap { request in
            guard request.isPending,
                  let candidate = live[request.id],
                  candidate.method == request.method,
                  candidate.threadID == request.threadID,
                  candidate.turnID == request.turnID,
                  candidate.itemID == request.itemID,
                  candidate.resolution == "pending" else { return nil }
            return request.id
        })
    }

    func close(_ session: HarnessSessionHandle) async {
        presentationTasks.removeValue(forKey: session.localSessionID)?.cancel()
        presentationContinuations.removeValue(forKey: session.localSessionID)?.finish()
        presentationBySessionID.removeValue(forKey: session.localSessionID)
        presentationChains.removeValue(forKey: session.localSessionID)
        presentationResyncs.remove(session.localSessionID)
        publishedChainSessionIDs.remove(session.localSessionID)
        answerableRequestsBySessionID.removeValue(forKey: session.localSessionID)
        activeTurnIDs.removeValue(forKey: session.localSessionID)
        await core.close(session)
    }

    /// `startingLivePatches` asks the adapter to restart the session's live patch chain, which
    /// it does with its next live update.
    private func readPresentation(
        for session: HarnessSessionHandle,
        refresh: Bool,
        startingLivePatches: Bool = false
    ) async throws -> CodexTaskState {
        try await readPresentation(
            localSessionID: session.localSessionID,
            refresh: refresh,
            startingLivePatches: startingLivePatches
        )
    }

    private func readPresentation(
        localSessionID: UUID,
        refresh: Bool,
        startingLivePatches: Bool
    ) async throws -> CodexTaskState {
        let snapshot: HarnessProtocolCodexPresentationSnapshot = try await core.perform(
            .codexPresentationRead,
            params: HarnessProtocolCodexPresentationReadParams(
                localSessionID: localSessionID,
                refresh: refresh,
                livePatches: startingLivePatches && acceptsPresentationPatches ? true : nil
            )
        )
        // A read answers outside the event order, so it is never the base of a patch.
        publishedChainSessionIDs.remove(localSessionID)
        return publish(snapshot)
    }

    private func acceptProtocolEvent(_ event: HarnessProtocolEventEnvelope) {
        guard let extensionEvent = event.payload.extensionEvent,
              extensionEvent.namespace == "yardlet.codex" else { return }
        switch extensionEvent.name {
        case HarnessProtocolCodexPresentationEvent.updated:
            guard let snapshot = try? payloadCodec.decode(
                HarnessProtocolCodexPresentationSnapshot.self,
                from: extensionEvent.payload
            ) else { return }
            let state = publish(snapshot)
            if acceptsPresentationPatches, let revision = snapshot.revision {
                presentationResyncs.remove(snapshot.localSessionID)
                publishedChainSessionIDs.insert(snapshot.localSessionID)
                presentationChains[snapshot.localSessionID] = CodexYHPPresentationChain(
                    revision: revision,
                    state: state,
                    serverRequestsByID: Dictionary(
                        snapshot.serverRequests.map { ($0.id, $0) }
                    ) { _, newest in newest }
                )
            }
        case HarnessProtocolCodexPresentationEvent.patched:
            guard acceptsPresentationPatches,
                  let patch = try? payloadCodec.decode(
                      HarnessProtocolCodexPresentationPatch.self,
                      from: extensionEvent.payload
                  ) else { return }
            let localSessionID = patch.localSessionID
            guard var chain = presentationChains.removeValue(forKey: localSessionID),
                  chain.revision == patch.baseRevision else {
                // A gap: this patch needs a base other than the one held. No patch applies
                // until a complete snapshot starts the chain again.
                requestPresentationResync(for: localSessionID)
                return
            }
            let changesPresentation = patch.thread != nil
                || !patch.approvals.isEmpty || !patch.removedApprovalIDs.isEmpty
                || !patch.serverRequests.isEmpty || !patch.removedServerRequestIDs.isEmpty
                || chain.state.lastAppliedSequence != patch.lastAppliedSequence
            guard CodexYHPProjection.apply(patch, to: &chain) else {
                requestPresentationResync(for: localSessionID)
                return
            }
            presentationChains[localSessionID] = chain
            appliedPresentationPatchCount += 1
            // When the last presentation published was the chain's, a patch that changed the
            // chain changed it too; comparing a long thread to learn that would cost what the
            // patch saved.
            let knownChanged = changesPresentation && publishedChainSessionIDs.contains(localSessionID)
            publish(
                chain.state,
                localSessionID: localSessionID,
                activeTurnID: patch.activeTurnID,
                answerableServerRequestIDs: patch.answerableServerRequestIDs,
                serverRequestsByID: chain.serverRequestsByID,
                knownChanged: knownChanged
            )
            publishedChainSessionIDs.insert(localSessionID)
        default:
            return
        }
    }

    /// After the read, the adapter's next live update is a complete snapshot, so patches that
    /// arrive before it were sent before the read and are dropped without asking again.
    private func requestPresentationResync(for localSessionID: UUID) {
        guard presentationResyncs.insert(localSessionID).inserted else { return }
        presentationResyncCount += 1
        Task { [weak self] in
            do {
                _ = try await self?.readPresentation(
                    localSessionID: localSessionID,
                    refresh: false,
                    startingLivePatches: true
                )
            } catch {
                await self?.endPresentationResync(for: localSessionID)
            }
        }
    }

    private func endPresentationResync(for localSessionID: UUID) {
        presentationResyncs.remove(localSessionID)
    }

    @discardableResult
    private func publish(_ snapshot: HarnessProtocolCodexPresentationSnapshot) -> CodexTaskState {
        let state = CodexYHPProjection.presentation(snapshot)
        publish(
            state,
            localSessionID: snapshot.localSessionID,
            activeTurnID: snapshot.activeTurnID,
            answerableServerRequestIDs: snapshot.answerableServerRequestIDs,
            serverRequestsByID: Dictionary(
                snapshot.serverRequests.map { ($0.id, $0) }
            ) { _, newest in newest }
        )
        return state
    }

    private func publish(
        _ state: CodexTaskState,
        localSessionID: UUID,
        activeTurnID: String?,
        answerableServerRequestIDs: [String],
        serverRequestsByID: [String: HarnessProtocolCodexServerRequest],
        knownChanged: Bool = false
    ) {
        // Events cross YHP after the answers they may predate, so a presentation applied after a
        // submit can still be one from before its turn.
        if state.knowsActiveTurn(activeTurnIDs[localSessionID]) {
            activeTurnIDs[localSessionID] = activeTurnID
        }
        answerableRequestsBySessionID[localSessionID] = Dictionary(
            answerableServerRequestIDs.compactMap { id in serverRequestsByID[id].map { (id, $0) } }
        ) { _, newest in newest }
        if knownChanged || presentationBySessionID[localSessionID] != state {
            presentationBySessionID[localSessionID] = state
            presentationContinuations[localSessionID]?.yield(state)
        }
    }

    private func performSessionAction(
        _ method: HarnessProtocolMethodID,
        session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await core.perform(
            method,
            params: HarnessProtocolSessionReference(localSessionID: session.localSessionID)
        )
    }

    private func sessionID() throws -> UUID {
        guard let localSessionID = presentationBySessionID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }).first else {
            throw HarnessAdapterError.capabilityUnavailable(
                "Codex controls require an attached session"
            )
        }
        return localSessionID
    }

    private func nextClientTurnID() -> String {
        defer { nextClientTurnSequence += 1 }
        return "yardlet-codex-turn-\(nextClientTurnSequence)"
    }
}

/// The thread lifecycle crosses YHP as the typed `yardlet.codex.thread.*` requests.
extension YHPCodexCompatibilityAdapter: CodexBackgroundTerminalControlling {
    func backgroundTerminals(in session: HarnessSessionHandle) async throws -> [CodexBackgroundTerminal] {
        try await requireBackgroundTerminals().backgroundTerminals(in: session)
    }

    func terminateBackgroundTerminal(processID: String, in session: HarnessSessionHandle) async throws {
        try await requireBackgroundTerminals().terminateBackgroundTerminal(processID: processID, in: session)
    }

    func cleanBackgroundTerminals(in session: HarnessSessionHandle) async throws {
        try await requireBackgroundTerminals().cleanBackgroundTerminals(in: session)
    }

    private func requireBackgroundTerminals() throws -> any CodexBackgroundTerminalControlling {
        guard let backgroundTerminalControl else {
            throw HarnessAdapterError.capabilityUnavailable("Background terminals are unavailable")
        }
        return backgroundTerminalControl
    }
}

extension YHPCodexCompatibilityAdapter: HarnessSessionLifecycleProviding {
    func archiveProviderSession(_ session: HarnessSessionHandle) async throws {
        try await archiveThread(session)
    }

    func unarchiveProviderSession(providerSessionID: String) async throws {
        try await unarchiveThread(threadID: providerSessionID)
    }

    func deleteProviderSession(_ session: HarnessSessionHandle) async throws {
        try await deleteThread(session)
    }

    func renameProviderSession(_ session: HarnessSessionHandle, to title: String) async throws {
        try await setThreadName(title, for: session)
    }
}

extension YHPCodexCompatibilityAdapter: HarnessTaskTitleSuggesting {
    func suggestTaskTitle(fromRecentConversation excerpt: String) async throws -> String {
        let result: HarnessProtocolCodexTaskTitleSuggestResult = try await core.perform(
            .codexTaskTitleSuggest, params: HarnessProtocolCodexTaskTitleSuggestParams(excerpt: excerpt))
        return result.title
    }
}

/// A Codex task forks its attached thread through YHP (`yardlet.codex.session.fork`).
extension YHPCodexCompatibilityAdapter: HarnessSessionBranching {
    nonisolated var sessionBranchMethod: HarnessSessionBranchMethod? { .attachedSession }
}

/// A session's presentation at the newest revision the host applied, with the wire form of its
/// server requests, which answerability checks against.
struct CodexYHPPresentationChain: Equatable, Sendable {
    var revision: UInt64
    var state: CodexTaskState
    var serverRequestsByID: [String: HarnessProtocolCodexServerRequest]
}

enum CodexYHPProjection {
    static func presentation(
        _ snapshot: HarnessProtocolCodexPresentationSnapshot
    ) -> CodexTaskState {
        CodexTaskState(
            thread: snapshot.thread.map(thread),
            approvalsByID: Dictionary(
                uniqueKeysWithValues: snapshot.approvals.map { ($0.id, approval($0)) }
            ),
            serverRequestsByID: Dictionary(
                uniqueKeysWithValues: snapshot.serverRequests.map { ($0.id, serverRequest($0)) }
            ),
            lastAppliedSequence: snapshot.lastAppliedSequence
        )
    }

    /// Applies `patch` to the chain at its base revision. Only the turns and items the patch
    /// names are projected; everything else keeps the chain's values. Returns false, leaving the
    /// chain unusable, when the patch names something the chain does not hold.
    static func apply(
        _ patch: HarnessProtocolCodexPresentationPatch,
        to chain: inout CodexYHPPresentationChain
    ) -> Bool {
        var state = chain.state
        chain.state = .empty
        if let threadPatch = patch.thread {
            guard var thread = state.thread else { return false }
            state.thread = nil
            guard apply(threadPatch, to: &thread) else { return false }
            state.thread = thread
        }
        for id in patch.removedApprovalIDs { state.approvalsByID.removeValue(forKey: id) }
        for value in patch.approvals { state.approvalsByID[value.id] = approval(value) }
        for id in patch.removedServerRequestIDs {
            state.serverRequestsByID.removeValue(forKey: id)
            chain.serverRequestsByID.removeValue(forKey: id)
        }
        for value in patch.serverRequests {
            state.serverRequestsByID[value.id] = serverRequest(value)
            chain.serverRequestsByID[value.id] = value
        }
        state.lastAppliedSequence = patch.lastAppliedSequence
        chain.state = state
        chain.revision = patch.revision
        return true
    }

    private static func apply(
        _ patch: HarnessProtocolCodexThreadPatch,
        to thread: inout CodexThreadState
    ) -> Bool {
        if let fields = patch.fields {
            guard fields.id == thread.id else { return false }
            let turns = thread.turns
            thread.turns = []
            thread = self.thread(fields)
            thread.turns = turns
        }
        guard let order = patch.turnIDs else {
            for turnPatch in patch.turns {
                guard let index = thread.turns.lastIndex(where: { $0.id == turnPatch.id }),
                      apply(turnPatch, to: &thread.turns[index]) else { return false }
            }
            return true
        }
        let patches = Dictionary(patch.turns.map { ($0.id, $0) }) { _, newest in newest }
        let ordered = Set(order)
        guard patches.count == patch.turns.count,
              ordered.count == order.count,
              patches.keys.allSatisfy(ordered.contains) else { return false }
        var existing = Dictionary(thread.turns.map { ($0.id, $0) }) { first, _ in first }
        thread.turns = []
        var turns: [CodexTurnState] = []
        turns.reserveCapacity(order.count)
        for id in order {
            if var turn = existing.removeValue(forKey: id) {
                if let turnPatch = patches[id] {
                    guard apply(turnPatch, to: &turn) else { return false }
                }
                turns.append(turn)
            } else {
                guard let turnPatch = patches[id], let turn = addedTurn(turnPatch) else { return false }
                turns.append(turn)
            }
        }
        thread.turns = turns
        return true
    }

    private static func addedTurn(_ patch: HarnessProtocolCodexTurnPatch) -> CodexTurnState? {
        guard let fields = patch.fields, fields.id == patch.id, patch.itemIDs != nil else { return nil }
        var turn = self.turn(fields)
        turn.items = []
        return apply(patch, to: &turn, applyingFields: false) ? turn : nil
    }

    private static func apply(
        _ patch: HarnessProtocolCodexTurnPatch,
        to turn: inout CodexTurnState,
        applyingFields: Bool = true
    ) -> Bool {
        if applyingFields, let fields = patch.fields {
            guard fields.id == turn.id else { return false }
            let items = turn.items
            turn.items = []
            turn = self.turn(fields)
            turn.items = items
        }
        guard let order = patch.itemIDs else {
            for value in patch.items {
                guard let index = turn.items.lastIndex(where: { $0.id == value.id }) else { return false }
                turn.items[index] = item(value)
            }
            return true
        }
        let changed = Dictionary(patch.items.map { ($0.id, $0) }) { _, newest in newest }
        let ordered = Set(order)
        guard changed.count == patch.items.count,
              ordered.count == order.count,
              changed.keys.allSatisfy(ordered.contains) else { return false }
        var existing = Dictionary(turn.items.map { ($0.id, $0) }) { first, _ in first }
        turn.items = []
        var items: [CodexItemState] = []
        items.reserveCapacity(order.count)
        for id in order {
            if let value = changed[id] {
                items.append(item(value))
            } else if let kept = existing.removeValue(forKey: id) {
                items.append(kept)
            } else {
                return false
            }
        }
        turn.items = items
        return true
    }

    static func thread(_ value: HarnessProtocolCodexThread) -> CodexThreadState {
        CodexThreadState(
            id: value.id,
            sessionID: value.sessionID,
            name: value.name,
            preview: value.preview,
            workspacePath: value.workspacePath,
            cliVersion: value.cliVersion,
            modelProvider: value.modelProvider,
            parentThreadID: value.parentThreadID,
            forkedFromID: value.forkedFromID,
            status: threadStatus(value.status, activeFlags: value.activeFlags),
            canAcceptDirectInput: value.canAcceptDirectInput,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            turns: value.turns.map(turn),
            turnsNextCursor: value.turnsNextCursor,
            turnsBackwardsCursor: value.turnsBackwardsCursor,
            itemsBackwardsCursor: value.itemsBackwardsCursor,
            raw: value.raw
        )
    }

    static func turn(_ value: HarnessProtocolCodexTurn) -> CodexTurnState {
        CodexTurnState(
            id: value.id,
            status: turnStatus(value.status),
            startedAt: value.startedAt,
            completedAt: value.completedAt,
            durationMilliseconds: value.durationMilliseconds,
            itemsView: itemsView(value.itemsView),
            items: value.items.map(item),
            itemsNextCursor: value.itemsNextCursor,
            plan: value.plan.map { plan in
                CodexPlanState(
                    explanation: plan.explanation,
                    steps: plan.steps.map { step in
                        CodexPlanStep(
                            id: step.id,
                            text: step.text,
                            status: planStatus(step.status)
                        )
                    }
                )
            },
            tokenUsage: value.tokenUsage.map(tokenUsage),
            error: value.error,
            raw: value.raw,
            diff: value.diff,
            retryingError: value.retryingError
        )
    }

    static func item(_ value: HarnessProtocolCodexItem) -> CodexItemState {
        var projected = CodexTaskDecoder().item(
            from: value.rendered ?? value.raw,
            fallbackID: value.id,
            lifecycle: CodexItemLifecycle(rawValue: value.lifecycle) ?? .historical
        )
        projected.startedAt = value.startedAt
        projected.completedAt = value.completedAt
        projected.raw = value.raw
        return projected
    }

    static func collaborationMode(
        _ value: HarnessProtocolCodexCollaborationMode
    ) -> CodexCollaborationPreset {
        CodexCollaborationPreset(
            name: value.name,
            mode: value.mode,
            model: value.model,
            reasoningEffort: value.reasoningEffort
        )
    }

    static func threadSummary(
        _ value: HarnessProtocolCodexThreadSummary
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: value.id,
            title: value.title,
            preview: value.preview,
            workspaceURL: URL(filePath: value.workspacePath).standardizedFileURL,
            updatedAt: value.updatedAt,
            forkedFromID: value.forkedFromID,
            recencyAt: value.recencyAt
        )
    }

    static func serverResponse(
        _ response: CodexServerRequestResponse
    ) -> HarnessProtocolCodexServerResponse {
        switch response {
        case let .command(decision):
            return makeResponse(kind: .command, decision: decision.rawValue)
        case let .fileChange(decision):
            return makeResponse(kind: .fileChange, decision: .string(decision.rawValue))
        case let .permissions(permissions, scope, strictAutoReview):
            return HarnessProtocolCodexServerResponse(
                kind: .permissions,
                decision: nil,
                permissions: permissions,
                scope: scope.rawValue,
                strictAutoReview: strictAutoReview,
                answers: nil,
                action: nil,
                content: nil,
                contentItems: nil,
                success: nil
            )
        case let .toolUserInput(answers):
            return HarnessProtocolCodexServerResponse(
                kind: .toolUserInput,
                decision: nil,
                permissions: nil,
                scope: nil,
                strictAutoReview: nil,
                answers: answers,
                action: nil,
                content: nil,
                contentItems: nil,
                success: nil
            )
        case let .mcpElicitation(action, content, meta):
            return HarnessProtocolCodexServerResponse(
                kind: .mcpElicitation,
                decision: nil,
                permissions: nil,
                scope: nil,
                strictAutoReview: nil,
                answers: nil,
                action: action.rawValue,
                content: content,
                contentItems: nil,
                success: nil,
                meta: meta
            )
        case let .dynamicToolCall(contentItems, success):
            return HarnessProtocolCodexServerResponse(
                kind: .dynamicToolCall,
                decision: nil,
                permissions: nil,
                scope: nil,
                strictAutoReview: nil,
                answers: nil,
                action: nil,
                content: nil,
                contentItems: contentItems,
                success: success
            )
        case let .legacyReview(decision):
            return makeResponse(kind: .legacyReview, decision: decision.rawValue)
        }
    }

    private static func makeResponse(
        kind: HarnessProtocolCodexServerResponseKind,
        decision: JSONValue
    ) -> HarnessProtocolCodexServerResponse {
        HarnessProtocolCodexServerResponse(
            kind: kind,
            decision: decision,
            permissions: nil,
            scope: nil,
            strictAutoReview: nil,
            answers: nil,
            action: nil,
            content: nil,
            contentItems: nil,
            success: nil
        )
    }

    private static func approval(
        _ value: HarnessProtocolCodexApproval
    ) -> CodexApprovalState {
        CodexApprovalState(
            id: value.id,
            method: value.method,
            threadID: value.threadID,
            turnID: value.turnID,
            itemID: value.itemID,
            resolution: value.resolution == "resolved" ? .resolved(value.result) : .pending,
            raw: value.raw
        )
    }

    private static func serverRequest(
        _ value: HarnessProtocolCodexServerRequest
    ) -> CodexServerRequestState {
        let resolution: CodexServerRequestResolution
        switch value.resolution {
        case "resolved":
            resolution = .resolved(value.result)
        case "rejected":
            resolution = .rejected(
                code: value.rejectionCode ?? -1,
                message: value.rejectionMessage ?? "Request rejected"
            )
        default:
            resolution = .pending
        }
        return CodexServerRequestState(
            id: value.id,
            method: value.method,
            kind: CodexServerRequestKind(wireName: value.kind),
            threadID: value.threadID,
            turnID: value.turnID,
            itemID: value.itemID,
            params: value.params,
            resolution: resolution
        )
    }

    private static func tokenUsage(
        _ value: HarnessProtocolCodexThreadTokenUsage
    ) -> CodexThreadTokenUsage {
        CodexThreadTokenUsage(
            total: tokenUsage(value.total),
            last: tokenUsage(value.last),
            modelContextWindow: value.modelContextWindow
        )
    }

    private static func tokenUsage(
        _ value: HarnessProtocolCodexTokenUsage
    ) -> CodexTokenUsageBreakdown {
        CodexTokenUsageBreakdown(
            inputTokens: value.inputTokens,
            cachedInputTokens: value.cachedInputTokens,
            cacheWriteInputTokens: value.cacheWriteInputTokens,
            outputTokens: value.outputTokens,
            reasoningOutputTokens: value.reasoningOutputTokens,
            totalTokens: value.totalTokens
        )
    }

    private static func threadStatus(
        _ value: String,
        activeFlags: [String]
    ) -> CodexThreadRuntimeStatus {
        switch value {
        case "not_loaded": .notLoaded
        case "idle": .idle
        case "active": .active(flags: activeFlags)
        case "system_error": .systemError
        default: .unknown(.string(value))
        }
    }

    private static func turnStatus(_ value: String) -> CodexTurnStatus {
        switch value {
        case "in_progress": .inProgress
        case "completed": .completed
        case "interrupted": .interrupted
        case "failed": .failed
        default: .unknown(value)
        }
    }

    private static func itemsView(_ value: String) -> CodexItemsView {
        switch value {
        case "not_loaded": .notLoaded
        case "summary": .summary
        case "full": .full
        default: .unknown(value)
        }
    }

    private static func planStatus(_ value: String) -> CodexPlanStepStatus {
        switch value {
        case "pending": .pending
        case "in_progress": .inProgress
        case "completed": .completed
        default: .unknown(value)
        }
    }
}
