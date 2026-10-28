import SwiftUI

/// The record a conversation is drawn from. The renderer projects it into `ConversationPresentation`
/// and reads only that, apart from what a card still draws from its record (`source`).
enum ConversationSource {
    /// A Codex thread's typed state (`CodexConversationProjection`).
    case codex(CodexTaskState, workspaceURL: URL, historySelection: CodexHistorySearchSelection?)
    /// A shared transcript (`TranscriptConversationProjection`).
    case transcript(
        entries: [TranscriptEntry], harness: HarnessKind, status: SessionStatus, latestTurnIsComplete: Bool
    )
}

/// The one conversation renderer (plan A5): a scrolling column of turns with the turn rail beside
/// it, whatever record the turns come from. It plugs in once what every conversation shares (A5.2): find, following the latest output, the reading position,
/// keeping the view still while earlier turns load, and the task's actions.
///
/// It owns a `ConversationProjectionCache`, so an update projects again only the turns it changed.
///
/// Every conversation looks the same whatever its harness (D12, plan M12f): the Codex timeline's
/// spacing, bubble and rail (`ConversationLayout`). Its turns are laid out whole, in an eager stack
/// (`scrollView`), and an update draws again only the turns it changed (`ConversationTurnView` and the
/// rail compare `.equatable()`); following pins a growing conversation to its bottom.
///
/// A conversation draws its latest 10 turns (`ConversationTurnWindow`, plan A5.3, D11); scrolling up
/// to the top brings earlier ones in, 10 at a time, once per load, as an upward infinite scroll does
/// (`TranscriptTopLoading`), and then asks a Codex thread for its earlier pages, or reads more of a
/// Claude transcript a read took from its end (`ConversationEarlierTurns.providerFile`); the rail's
/// "Load more history" asks the same way. As earlier turns arrive above them, the turns being read
/// stay where they are in the viewport (`TranscriptReadingTracker.placeToKeep`). Going back to the
/// latest output — a sent message, a new turn, a request to answer, "Latest response" — draws the
/// latest 10 again. Find, saved places and an opened history result read the whole loaded
/// conversation and widen the window to the turn they reach.
///
/// The source can change under the same view (plan M7): a Codex task draws its shared transcript
/// before its first turn and while detached, then its thread once the thread has turns. The scroll
/// view, following and the reading position stay; saved places and "the latest request" carry over
/// through `ConversationAnchorResolver`, which knows how a detached snapshot names a thread's turns.
struct ConversationTimeline: View {
    let source: ConversationSource
    /// Where the conversation sits: a task's own, or inside a side panel.
    var placement: ConversationPlacement = .task
    /// The provider thread a transcript source was flattened from (a detached Codex task); a Codex
    /// source names its own.
    var snapshotThreadID: String? = nil
    var readingPosition: TranscriptReadingPosition? = nil
    /// A bookmark an earlier renderer kept for this conversation (a Codex task's shared-transcript
    /// bookmark). It is read once, when reading starts, and then cleared: from then on
    /// `readingPosition` is the conversation's one bookmark.
    var earlierReadingPosition: TranscriptReadingPosition? = nil
    var actions = ConversationActions()
    /// How many of the latest turns are drawn at first (`ConversationTurnWindow`).
    var turnWindowCount = ConversationTurnWindow.initialTurnCount
    /// The conversation is being read from the provider's own history. With no turns yet it says it
    /// is loading, not "Start a conversation": a task opened for the first time this launch, before
    /// its saved conversation arrives, is not an empty task.
    var isLoading = false
    /// Names the conversation in the blank-viewport log (`ConversationBlankViewportLog`): its task.
    var diagnosticID: String? = nil
    /// What the task keeps of its conversation between the times it is shown: its projection and its
    /// turns' hosting views (`ConversationTurnHost`). Without one the conversation keeps its own while
    /// it is shown.
    var renderState: ConversationRenderState? = nil

    @State private var ownRenderState = ConversationRenderState()
    /// Turns "Load more history" added to the window.
    @State private var addedTurnCount = 0
    /// The earliest turn the reader went to (a find match, a saved place, a history result), kept drawn.
    @State private var earliestReadTurnID: String?
    /// The reader asked the provider for its earlier turns, so every loaded turn is drawn: the page
    /// they asked for, whatever its length, and everything after it.
    @State private var drawsEveryLoadedTurn = false
    @State private var latestRequest = ConversationLatestRequest()
    @State private var readingTracker = TranscriptReadingTracker()
    @State private var handledInitialSearch = false
    @State private var focusedTurnID: String?
    @State private var turnFocusRequest = 0
    @State private var scrollState = TranscriptScrollFollowState()
    @State private var showsFileRewind = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationFind) private var find
    /// A place in this conversation another view asked to show (a file's related task's call).
    @Environment(\.conversationPlace) private var place
    /// The task's folder, which a transcript's file changes are read against.
    @Environment(\.transcriptWorkspaceURL) private var transcriptWorkspaceURL

    var body: some View {
        // The whole conversation is what find searches and saved places resolve against; the window
        // is what is drawn.
        let whole = project()
        let window = turnWindow
        let presentation = withProviderRetry(window?.apply(to: whole) ?? whole)
        let turns = presentation.turns
        let _ = rendering.keep(turnIDs: turns.map(\.id))
        let context = itemContext(presentation)
        let anchors = ConversationAnchorResolver(presentation: presentation, threadID: threadID)
        let wholeAnchors = ConversationAnchorResolver(presentation: whole, threadID: threadID)
        let latestRequestID = latestRequest.id(latestTurnID: turns.last?.id) { anchors.isRenamed($0, as: $1) }
        HStack(spacing: 0) {
            if showsTurnRail(presentation) {
                CodexTurnRail(
                    turns: turns,
                    focusedTurnID: scrollState.isFollowing ? turns.last?.id : focusedTurnID,
                    onFocus: { turnID in
                        readingTracker.cancelRestoration()
                        focusedTurnID = turnID
                        scrollState.isFollowing = false
                        turnFocusRequest += 1
                    },
                    hasMoreTurns: presentation.earlier != .none,
                    moreTurns: "\(presentation.earlier)",
                    onLoadMore: { loadEarlierTurns(presentation.earlier, loadedTurnCount: whole.turns.count) }
                )
                .equatable()
                .accessibilitySortPriority(ParityAccessibility.surfacePicker - 1)
            }

            ScrollViewReader { proxy in
                scrollView {
                    if turns.isEmpty {
                        emptyState
                    }
                    ForEach(turns) { turn in
                        ConversationTurnHost(turn: turn, context: context, handlers: handlers(for: turn),
                                             renderState: rendering)
                            .equatable()
                            .transcriptReadingAnchor(turn.id, tracker: readingTracker)
                    }
                }
                .coordinateSpace(name: readingTracker.coordinateSpace)
                .modifier(TranscriptScrollFollowing(
                    latestRequestID: latestRequestID, state: $scrollState,
                    readingPosition: readingPosition, readingTracker: readingTracker,
                    readingItemIDs: turns.map(\.id),
                    pendingRequestIDs: presentation.pendingRequestIDs,
                    readingAnchors: readingAnchors(wholeAnchors, whole: whole, window: window),
                    pinsGrowthToBottom: true,
                    loadEarlier: presentation.earlier == .none ? nil : {
                        loadEarlierTurns(presentation.earlier, loadedTurnCount: whole.turns.count)
                    },
                    earlierKey: presentation.earlier == .none ? nil
                        : "\(presentation.earlier)|\(turns.first?.id ?? "")",
                    keepsPlaceAsEarlierItemsArrive: true,
                    diagnosticID: diagnosticID,
                    onReturnToLatest: returnToLatestTurns
                ))
                .accessibilitySortPriority(placement.accessibilitySortPriority)
                .background {
                    ConversationFindScrollDriver(find: find, proxy: proxy) {
                        readingTracker.cancelRestoration()
                        if scrollState.isFollowing { scrollState.isFollowing = false }
                    }
                    if let find, find.isPresented {
                        ConversationFindFeeder(find: find, source: .conversation(whole))
                    }
                }
                // A match in a turn the window leaves out widens the window to it first (plan A5.2),
                // then goes there once the turn is drawn.
                .onChange(of: find?.scrollRequest) { _, request in
                    guard let request, let window, window.hides(request.scrollID, in: whole) else { return }
                    earliestReadTurnID = request.scrollID
                    Task { @MainActor in
                        await Task.yield()
                        guard find?.scrollRequest == request else { return }
                        proxy.scrollTo(request.scrollID, anchor: .center)
                        try? await Task.sleep(for: .milliseconds(80))
                        guard find?.scrollRequest == request else { return }
                        proxy.scrollTo(ConversationFindAnchor.activeMatch, anchor: .center)
                    }
                }
                .onChange(of: turnFocusRequest) { _, _ in
                    if let focusedTurnID { proxy.scrollTo(focusedTurnID, anchor: .center) }
                }
                .onChange(of: readingTracker.visibleAnchorID) { _, id in
                    if !scrollState.isFollowing, let id { focusedTurnID = id }
                }
                .task(id: historySelection) {
                    let restoresReading = !handledInitialSearch && readingPosition?.bookmark.followsLatest == false
                    handledInitialSearch = true
                    guard !restoresReading else { return }
                    guard historySelection != nil, let targetTurnID = Self.firstHistoryMatch(in: whole)
                    else { return }
                    // A match in a turn the window leaves out widens the window to it first.
                    if let window, window.hides(targetTurnID, in: whole) { earliestReadTurnID = targetTurnID }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    readingTracker.cancelRestoration()
                    scrollState.isFollowing = false
                    focusedTurnID = targetTurnID
                    withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(targetTurnID, anchor: .center)
                    }
                }
                // A call another view asked for (a file's related task): the turn holding it, at its top,
                // widening the window to it first as a history result does.
                .task(id: place?.request.id) {
                    guard placement == .task, let place else { return }
                    defer { place.done() }
                    guard let targetTurnID = Self.turn(holding: place.request.callID, in: whole) else { return }
                    readingTracker.cancelRestoration()
                    scrollState.isFollowing = false
                    focusedTurnID = targetTurnID
                    if let window, window.hides(targetTurnID, in: whole) { earliestReadTurnID = targetTurnID }
                    // Once the widened window is drawn, and again once the place kept as its turns arrived
                    // above has settled, as find goes to a match.
                    for delay in [30, 120] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(targetTurnID, anchor: .top)
                    }
                }
            }
        }
        .background {
            if placement.paintsCanvas { ParityTheme.canvas }
        }
        .sheet(isPresented: $showsFileRewind) {
            if let rewindActions = actions.rewind { ClaudeFileRewindSheet(actions: rewindActions) }
        }
    }

    // MARK: - Projection

    private var rendering: ConversationRenderState { renderState ?? ownRenderState }

    private func project() -> ConversationPresentation {
        let cache = rendering.projection
        var presentation: ConversationPresentation
        switch source {
        case let .codex(state, workspaceURL, historySelection):
            presentation = cache.codex(state, workspaceURL: workspaceURL, historySelection: historySelection)
        case let .transcript(entries, harness, status, latestTurnIsComplete):
            presentation = cache.transcript(
                entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete
            )
            // The provider's file holds turns before the ones read from it.
            if actions.readEarlierHistory != nil { presentation.earlier = .providerFile }
        }
        presentation.appendHeldRequests(actions.heldRequests)
        return presentation
    }

    /// A provider retrying its response stream reads on the running turn's status line (D6): Claude
    /// Code's `api_retry`, which the task's notices carry. A Codex thread carries its own reconnects.
    private func withProviderRetry(_ presentation: ConversationPresentation) -> ConversationPresentation {
        guard let retry = actions.providerNotices?.retry, let last = presentation.turns.indices.last,
              presentation.turns[last].status == .running else { return presentation }
        var retrying = presentation
        retrying.turns[last].progress = .reconnecting(ProviderNoticeText.retry(retry))
        return retrying
    }

    /// The Codex thread the conversation is, or was flattened from.
    private var threadID: String? {
        if case let .codex(state, _, _) = source { return state.thread?.id ?? snapshotThreadID }
        return snapshotThreadID
    }

    /// Saved places read against the whole conversation. A place in a turn the window leaves out
    /// widens the window to it; the tracker keeps the place until the turn is drawn.
    private func readingAnchors(
        _ anchors: ConversationAnchorResolver, whole: ConversationPresentation, window: ConversationTurnWindow?
    ) -> TranscriptReadingAnchors {
        TranscriptReadingAnchors(
            start: { [readingPosition, earlierReadingPosition, $earliestReadTurnID] in
                let saved = readingPosition?.bookmark ?? .init()
                let earlier = earlierReadingPosition?.bookmark
                if let earlierReadingPosition, earlier != TranscriptReadingBookmark() {
                    earlierReadingPosition.bookmark = .init()
                }
                let bookmark = anchors.startingBookmark(saved: saved, earlier: earlier)
                if !bookmark.followsLatest, let turnID = bookmark.anchorID, let window,
                   window.hides(turnID, in: whole) {
                    $earliestReadTurnID.wrappedValue = turnID
                }
                return bookmark
            },
            resolve: { anchors.resolve($0) }
        )
    }

    // MARK: - Turn window

    /// The window over the loaded turns: a transcript's, or the pages a Codex thread loaded.
    private var turnWindow: ConversationTurnWindow? {
        guard !drawsEveryLoadedTurn else { return nil }
        return ConversationTurnWindow(turnCount: turnWindowCount + addedTurnCount, earliestTurnID: earliestReadTurnID)
    }

    /// The rail beside a conversation with more than one turn, or with earlier turns to bring in.
    private func showsTurnRail(_ presentation: ConversationPresentation) -> Bool {
        presentation.turns.count > 1 || presentation.earlier != .none
    }

    /// The reader went back to the latest output: the window draws the latest turns again, so a
    /// conversation read far back costs no more to draw than one never scrolled.
    private func returnToLatestTurns() {
        if addedTurnCount != 0 { addedTurnCount = 0 }
        if earliestReadTurnID != nil { earliestReadTurnID = nil }
        if drawsEveryLoadedTurn { drawsEveryLoadedTurn = false }
    }

    /// Brings in the turns before the first one drawn: the window's next step, the provider's
    /// earlier page, or more of the provider's file, whose turns the window's next step then draws.
    /// The rail's "Load more history" and scrolling up to the top both ask for them.
    private func loadEarlierTurns(_ earlier: ConversationEarlierTurns, loadedTurnCount: Int) {
        switch earlier {
        case .local: addedTurnCount += ConversationTurnWindow.step
        case .provider:
            drawsEveryLoadedTurn = true
            actions.loadMoreCodexTurns()
        case .providerFile:
            addedTurnCount = max(addedTurnCount, loadedTurnCount + ConversationTurnWindow.step - turnWindowCount)
            actions.readEarlierHistory?()
        case .none: break
        }
    }

    private var historySelection: CodexHistorySearchSelection? {
        if case let .codex(_, _, selection) = source { return selection }
        return nil
    }

    /// The turn holding the call the provider named `callID`: a Codex item, or a transcript's activity.
    static func turn(holding callID: String, in presentation: ConversationPresentation) -> String? {
        presentation.turns.first { turn in
            [turn.prompt, turn.notices, turn.work, turn.answers].contains { items in
                items.contains { item in
                    switch item.source {
                    case let .codex(codexItem, _): return codexItem.id == callID
                    case let .transcript(entry):
                        if case let .activity(activity, _) = entry.content { return activity.id == callID }
                        return false
                    }
                }
            }
        }?.id
    }

    /// The first turn holding an item the opened history result matches.
    static func firstHistoryMatch(in presentation: ConversationPresentation) -> String? {
        presentation.turns.first { turn in
            [turn.prompt, turn.notices, turn.work, turn.answers].contains { $0.contains(where: \.isHistoryMatch) }
        }?.id
    }

    // MARK: - Turns

    private func itemContext(_ presentation: ConversationPresentation) -> ConversationItemContext {
        var context = ConversationItemContext(harness: presentation.harness, workspaceURL: workspaceURL, actions: actions)
        if case let .transcript(entries, _, _, _) = source {
            context.lastEntryID = entries.last?.id
        }
        return context
    }

    private var workspaceURL: URL {
        if case let .codex(_, workspaceURL, _) = source { return workspaceURL }
        return transcriptWorkspaceURL ?? URL(filePath: "/")
    }

    /// The turn's controls, offered where the turn and the task both allow them.
    private func handlers(for turn: ConversationTurn) -> ConversationTurnHandlers {
        var handlers = ConversationTurnHandlers(loadMoreItems: { actions.loadMoreCodexItems(turn.id) })
        let turnID = turn.id
        // Every harness retries by the turn's ID, the way its own app does (`AppModel.retryTurn`).
        if turn.actions.canRetry, let retry = actions.retryTurn {
            handlers.retry = { retry(turnID) }
        }
        switch source {
        case let .codex(state, _, _):
            // Codex's own turn actions act on the provider's turn.
            let codexTurn = { state.thread?.turns.first { $0.id == turnID } }
            let rewind = actions.rewind
            let restoreDraft = actions.restoreDraft
            handlers.edit = { draft in
                if let beginCodexEdit = rewind?.beginCodexEdit {
                    if let turn = codexTurn() { beginCodexEdit(turn) }
                } else {
                    restoreDraft?(draft)
                }
            }
            handlers.fork = actions.forkCodexTurn.map { fork in { fork(turnID) } }
        case .transcript:
            // A transcript request goes back to the composer only where the task can take it.
            handlers.edit = actions.restoreDraft
            // The provider's own edit and file restore (Claude), and a fork of the whole
            // conversation from its latest turn (D10), in the turn menu.
            if let rewind = actions.rewind {
                handlers.editMessage = { target in rewind.beginClaudeEdit(target.text) }
                handlers.restoreFiles = { showsFileRewind = true }
            }
            if turn.actions.canFork, let branch = actions.branch {
                handlers.fork = { branch(.latest) }
            }
        }
        if let plan = turn.actions.planToImplement, let implement = actions.implementCodexPlan {
            handlers.implementPlan = { implement(plan) }
        }
        // A turn still running takes the answer into itself, as the Codex app answers from its panel.
        if !turn.actions.questionsToAnswer.isEmpty,
           let answer = turn.status.isTerminal ? actions.answerQuestion : actions.answerQuestionWhileWorking {
            handlers.answerQuestion = answer
        }
        return handlers
    }

    // MARK: - Layout

    /// The scroll view around the turns. Its content is the stack itself, never a conditional view:
    /// a scroll view whose content is a conditional view does not keep its bottom in view as the
    /// content grows past it (`defaultScrollAnchor(.bottom, for: .sizeChanges)`), which following
    /// relies on.
    ///
    /// The stack is eager: every turn the window draws is laid out, so the scroll view always knows
    /// where each one is. A lazy stack estimated the turns it had not laid out from the ones it had,
    /// and a working conversation's turns range from a line to many screens: as the running turn
    /// streamed, folded its work, took a request or a queued message, or the composer grew, the
    /// estimate moved by thousands of points, and the stack lost the turns in view — the conversation
    /// drew nothing, for up to a second or until the reader scrolled (`ConversationBlankFrameTests`).
    /// The turn window keeps what is laid out to a few screens (`ConversationTurnWindow`).
    private func scrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConversationLayout.turnSpacing, content: content)
                .scrollTargetLayout()
                .padding(.horizontal, ParityTheme.conversationInset)
                .frame(maxWidth: ParityTheme.contentWidth, alignment: .leading)
                .padding(.top, ConversationLayout.topPadding)
                .padding(.bottom, ConversationLayout.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .center)
                // A drag from the margins or between turns selects, as a page's does.
                .background { ConversationPressBackdrop() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.string("Loading conversation"))
                .frame(maxWidth: .infinity)
                .padding(.top, 96)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(L10n.string("Start a conversation"))
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 96)
        }
    }
}

/// "The latest request", which following moves to whenever it changes. A conversation that renames
/// its turns (a detached Codex snapshot replaced by its thread) keeps it, so the reader is not taken
/// to the bottom when nothing new was sent. The renderer owns one as `@State`; nothing observes it.
final class ConversationLatestRequest {
    private var turnID: String?
    private var key: String?

    /// The key for `latestTurnID`. `isRenamed(old, new)` says the previous latest turn is the new
    /// one under a new name.
    func id(latestTurnID: String?, isRenamed: (String, String) -> Bool) -> String? {
        guard latestTurnID != turnID else { return key }
        defer { turnID = latestTurnID }
        if let previous = turnID, let latestTurnID, key != nil, isRenamed(previous, latestTurnID) { return key }
        key = latestTurnID
        return key
    }
}
