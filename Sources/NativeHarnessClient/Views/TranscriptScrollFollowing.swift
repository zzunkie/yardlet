import SwiftUI

private struct PauseTranscriptFollowingKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    /// For reading that moves away from the latest content, such as a sheet or more of a long
    /// answer. Opening or closing a card does not pause following.
    var pauseTranscriptFollowing: @MainActor @Sendable () -> Void {
        get { self[PauseTranscriptFollowingKey.self] }
        set { self[PauseTranscriptFollowingKey.self] = newValue }
    }
}

struct TranscriptScrollMetrics: Equatable {
    let height: CGFloat
    let viewport: CGSize
    let offset: CGFloat
    let distance: CGFloat

    func isUserMovement(from old: Self, interacting: Bool, positionedByUser: Bool, restoring: Bool) -> Bool {
        interacting || (positionedByUser && !restoring && old.height == height
            && old.viewport == viewport && abs(offset - old.offset) > 1)
    }
}

struct TranscriptScrollFollowState: Equatable {
    var isFollowing = true
    private(set) var isNearBottom = true

    var showsLatest: Bool { !isFollowing && !isNearBottom }

    mutating func observe(distance: CGFloat, userDriven: Bool) {
        isNearBottom = max(0, distance) <= 48
        // Content growth alone must not change the reader's choice to follow or pause.
        if userDriven { isFollowing = isNearBottom }
    }

    /// A request the person must answer holds the turn until it is answered, so a new one is
    /// brought into view and following resumes even when the reader had scrolled away. Returns
    /// whether the view should move to it.
    mutating func pendingRequestsChanged(from old: Set<String>, to new: Set<String>) -> Bool {
        guard !new.isSubset(of: old) else { return false }
        isFollowing = true
        return true
    }
}

/// When to bring earlier turns in as the reader scrolls up, as an upward infinite scroll does: once
/// the reader's own scrolling (not opening at the bottom, not restoring a place, not a jump to a find
/// match, not content growth) comes within `reach` of the top while the conversation has earlier
/// turns. One load at a time: a load is in flight until the earlier turns change (`key`), and the
/// next waits until the reader is away from the top again (the turns that arrived push them down)
/// or starts a new scroll, so one gesture does not ask twice before the first load is in view. The
/// reader moving well away from the top lets a load that brought nothing be asked for again.
struct TranscriptTopLoading: Equatable {
    /// How near the top, in points, the reader's scrolling asks for earlier turns.
    static let reach: CGFloat = 160

    /// The earlier turns a load was asked for, until they change.
    private(set) var inFlight: String?
    private var isArmed = true

    /// The reader started a new scroll.
    mutating func readerBeganScrolling() {
        isArmed = true
    }

    /// - Parameters:
    ///   - userDriven: the reader's own scrolling moved the conversation.
    ///   - key: names the earlier turns there are, and changes when a load brings them in; nil when
    ///     there are none.
    /// - Returns: whether to load the earlier turns now.
    mutating func shouldLoad(offset: CGFloat, userDriven: Bool, key: String?) -> Bool {
        if let inFlight, inFlight != key {
            // Arrived: the next load waits for the arrived turns to push the reader down.
            self.inFlight = nil
            isArmed = false
        }
        if offset > Self.reach { isArmed = true }
        if offset > Self.reach * 4 { inFlight = nil }
        guard userDriven, let key, offset <= Self.reach, isArmed, inFlight == nil else { return false }
        inFlight = key
        isArmed = false
        return true
    }

    /// Items arrived before the first one: it is still there, and no longer first.
    static func earlierItemsArrived(from old: [String], to new: [String]) -> Bool {
        guard let first = old.first, new.first != first, let index = new.firstIndex(of: first) else { return false }
        return index > 0
    }
}

/// A reader's scroll that goes on after the view kept their place as earlier turns arrived above it.
/// Moving the view back to that place ends SwiftUI's scroll phase and its user positioning, though
/// the reader's gesture or wheel goes on: without this, the rest of it would not be the reader's,
/// and reaching the new top would bring in nothing until a new scroll. Until the view stands still
/// for `pause`, the view moving with its content and viewport unchanged is still the reader's scroll.
struct TranscriptContinuedScroll: Equatable {
    /// How long the view stands still before the reader's scroll is over.
    static let pause: TimeInterval = 0.5

    private var lastMovement: Date?

    /// Whether the reader's scroll that went on across a kept place has not stood still for `pause`.
    func goesOn(at now: Date) -> Bool {
        lastMovement.map { now.timeIntervalSince($0) <= Self.pause } ?? false
    }

    /// The view kept the reader's place while they were scrolling.
    mutating func keptPlace(at now: Date) {
        lastMovement = now
    }

    /// SwiftUI reports the reader's scrolling again, or the view moved for something else.
    mutating func end() {
        lastMovement = nil
    }

    /// Whether the change from `old` to `new` is the reader's scroll going on.
    mutating func continues(from old: TranscriptScrollMetrics, to new: TranscriptScrollMetrics, at now: Date) -> Bool {
        guard lastMovement != nil else { return false }
        guard goesOn(at: now) else {
            lastMovement = nil
            return false
        }
        guard old.height == new.height, old.viewport == new.viewport, abs(new.offset - old.offset) > 0.5
        else { return false }
        lastMovement = now
        return true
    }
}

struct TranscriptScrollFollowing<RequestID: Hashable>: ViewModifier {
    let latestRequestID: RequestID?
    @Binding var state: TranscriptScrollFollowState
    var readingPosition: TranscriptReadingPosition? = nil
    var readingTracker: TranscriptReadingTracker? = nil
    var readingItemIDs: [String] = []
    /// Approvals and questions waiting for an answer. They sit at the end of the transcript.
    var pendingRequestIDs: Set<String> = []
    /// How saved places read in a conversation whose IDs can change; nil reads them as saved.
    var readingAnchors: TranscriptReadingAnchors? = nil
    /// Moves a followed conversation to its bottom whenever its content changes height. A conversation
    /// laid out in an eager stack needs it: the size-change anchor leaves it at the top once it grows
    /// past a viewport it was shorter than, and every later growth then stays out of view. A lazy
    /// stack's height also shrinks as it measures rows it had estimated, which left the end of a
    /// conversation just sent to out of view.
    var pinsGrowthToBottom = false
    /// Brings earlier turns in when the reader scrolls up to the top (`TranscriptTopLoading`); nil
    /// where the conversation has none. `earlierKey` names the earlier turns there are.
    var loadEarlier: (() -> Void)? = nil
    var earlierKey: String? = nil
    /// Keeps what the reader sees in place when items arrive before the first one, as earlier turns
    /// do: the first item in view goes back to where it was (`TranscriptReadingTracker.placeToKeep`).
    var keepsPlaceAsEarlierItemsArrive = false
    /// Names the conversation in the blank-viewport log (`ConversationBlankViewportLog`).
    var diagnosticID: String? = nil
    /// Told when the view goes to the latest output for the reader: a sent message or a new turn, a
    /// new request to answer, "Latest response".
    var onReturnToLatest: (() -> Void)? = nil
    @State private var position = ScrollPosition(edge: .bottom)
    /// Only while the blank-viewport log is on.
    @State private var blankMonitor: ConversationBlankViewportMonitor? =
        ConversationBlankViewportLog.isEnabled ? ConversationBlankViewportMonitor() : nil
    @State private var isUserScrolling = false
    /// What arrived below the end of a followed conversation while the reader scrolled it. The
    /// size-change anchor does not keep the end under the reader's gesture, and following does not
    /// move the view under it, so the end moves away by this much without the reader moving: it is
    /// not their distance from the end, and it comes into view when their gesture ends.
    @State private var arrivedUnderGesture: CGFloat = 0
    @State private var continuedScroll = TranscriptContinuedScroll()
    @State private var topLoading = TranscriptTopLoading()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .environment(\.pauseTranscriptFollowing, {
                readingTracker?.cancelRestoration()
                state.isFollowing = false
            })
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(state.isFollowing ? .bottom : nil, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: latestRequestID) { _, _ in
                blankMonitor?.note("new latest turn")
                let wasFollowing = state.isFollowing
                readingTracker?.followLatest()
                state.isFollowing = true
                moveToLatest(wasFollowing: wasFollowing)
            }
            .onChange(of: pendingRequestIDs) { old, new in
                blankMonitor?.note("requests to answer changed")
                let wasFollowing = state.isFollowing
                guard state.pendingRequestsChanged(from: old, to: new) else { return }
                readingTracker?.followLatest()
                moveToLatest(wasFollowing: wasFollowing)
            }
            .onAppear {
                if let blankMonitor {
                    blankMonitor.conversationID = diagnosticID ?? "-"
                    blankMonitor.note("opened")
                    blankMonitor.observe(itemCount: readingItemIDs.count)
                }
                guard readingTracker?.resumes(record: readingPosition) != true else { return }
                state.isFollowing = readingPosition?.bookmark.followsLatest ?? true
                readingTracker?.start(record: readingPosition, itemIDs: readingItemIDs,
                                      startingAt: readingAnchors?.start(), resolve: readingAnchors?.resolve)
                applyRestoration(readingTracker?.request)
            }
            .onDisappear { readingTracker?.hide() }
            .onChange(of: readingItemIDs) { old, ids in
                // Read from the layout before the change, which the items now in view still have.
                let arrived = keepsPlaceAsEarlierItemsArrive && !state.isFollowing
                    && TranscriptTopLoading.earlierItemsArrived(from: old, to: ids)
                let place = arrived ? readingTracker?.placeToKeep() : nil
                if let blankMonitor {
                    blankMonitor.note(TranscriptTopLoading.earlierItemsArrived(from: old, to: ids)
                        ? "earlier turns arrived" : "turns changed (\(old.count) to \(ids.count))")
                    blankMonitor.observe(itemCount: ids.count)
                }
                readingTracker?.updateItems(ids, resolve: readingAnchors?.resolve)
                // A saved place the new items let the tracker show again goes first.
                if let place, readingTracker?.isRestoring != true {
                    // Keeping the place ends SwiftUI's scroll phase; the reader's scroll goes on.
                    let now = Date()
                    if isUserScrolling || continuedScroll.goesOn(at: now) { continuedScroll.keptPlace(at: now) }
                    position.scrollTo(id: place.id, anchor: place.anchor)
                }
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0) { ids in
                readingTracker?.updateVisibleItems(ids)
                blankMonitor?.observe(visibleItems: ids.count)
                if ProcessInfo.processInfo.environment["NHC_SCROLL_TRACE"] != nil { print("[trace] visible \(ids.count)") }
            }
            .onChange(of: readingTracker?.request) { _, request in applyRestoration(request) }
            .onChange(of: readingTracker?.anchorRevision) { _, _ in applyRestoration(readingTracker?.request) }
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                TranscriptScrollMetrics(
                    height: geometry.contentSize.height,
                    viewport: geometry.containerSize,
                    offset: geometry.visibleRect.minY,
                    distance: max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                )
            } action: { old, new in
                // Keyboard and accessibility scrolling can bypass the tracking phase.
                // Moving toward earlier content must still release the bottom anchor.
                // A panel or text reflow also moves the offset. Only infer keyboard
                // scrolling when SwiftUI reports a user position and the layout stayed unchanged.
                let restoring = readingTracker?.isRestoring == true
                // The reader's scroll going on across a place the view kept (`TranscriptContinuedScroll`).
                let readerScrolling = isUserScrolling
                    || (continuedScroll.continues(from: old, to: new, at: Date()) && !restoring)
                let userDriven = new.isUserMovement(from: old, interacting: readerScrolling,
                    positionedByUser: position.isPositionedByUser, restoring: restoring)
                if userDriven, state.isFollowing, new.height != old.height {
                    arrivedUnderGesture += max(0, new.distance - old.distance)
                }
                if new.distance <= 1 { arrivedUnderGesture = 0 }
                if new.viewport.width >= 80, new.viewport.height >= 60 {
                    state.observe(distance: new.distance - arrivedUnderGesture, userDriven: userDriven)
                }
                if !state.isFollowing { arrivedUnderGesture = 0 }
                if pinsGrowthToBottom, state.isFollowing, !userDriven, new.height != old.height, new.distance > 1,
                   readingTracker?.isRestoring != true {
                    position.scrollTo(edge: .bottom)
                    if ProcessInfo.processInfo.environment["NHC_SCROLL_TRACE"] != nil { print("[trace] pin to bottom") }
                }
                if ProcessInfo.processInfo.environment["NHC_SCROLL_TRACE"] != nil {
                    print("[trace] geometry \(old.offset)/\(old.height) -> \(new.offset)/\(new.height) dist \(new.distance) follow \(state.isFollowing) user \(userDriven)")
                }
                if let blankMonitor {
                    if userDriven {
                        blankMonitor.note("scrolled")
                    } else if new.height != old.height {
                        blankMonitor.note(String(format: "content height %.0f to %.0f", old.height, new.height))
                    } else if new.viewport != old.viewport {
                        blankMonitor.note(String(format: "viewport %.0fx%.0f", new.viewport.width, new.viewport.height))
                    }
                    blankMonitor.observe(new, isFollowing: state.isFollowing)
                }
                readingTracker?.observe(offset: new.offset, height: new.height, viewport: new.viewport,
                                        followsLatest: state.isFollowing, userDriven: userDriven)
                // Only the reader's own scrolling: a jump to a find match or a turn the rail
                // names is not the reader scrolling up.
                if let loadEarlier, new.viewport.height >= 60,
                   topLoading.shouldLoad(offset: new.offset, userDriven: readerScrolling, key: earlierKey) {
                    loadEarlier()
                }
            }
            .onScrollPhaseChange { old, new, context in
                let wasUserScrolling = isUserScrolling
                isUserScrolling = new == .tracking || new == .interacting || new == .decelerating
                if (new == .tracking && old != .tracking) || (isUserScrolling && !wasUserScrolling) {
                    topLoading.readerBeganScrolling()
                }
                // SwiftUI tracks the reader's scrolling again. (The idle a kept place brings is not
                // the end of the reader's scroll.)
                if isUserScrolling { continuedScroll.end() }
                if isUserScrolling || (new == .idle && wasUserScrolling) {
                    state.observe(
                        distance: context.geometry.contentSize.height - context.geometry.visibleRect.maxY
                            - arrivedUnderGesture,
                        userDriven: true
                    )
                }
                // The reader's gesture over a followed conversation ended: what arrived under it comes
                // into view, as following would have brought it.
                if new == .idle, wasUserScrolling {
                    if pinsGrowthToBottom, state.isFollowing, arrivedUnderGesture > 0, readingTracker?.isRestoring != true {
                        position.scrollTo(edge: .bottom)
                    }
                    arrivedUnderGesture = 0
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if state.showsLatest {
                    Button {
                        blankMonitor?.note("latest response")
                        readingTracker?.followLatest()
                        state.isFollowing = true
                        moveToLatest(wasFollowing: false, animation: ParityMotion.easeOut(reduceMotion: reduceMotion))
                    } label: {
                        Label(L10n.string("Latest response"), systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(ParityTheme.elevated, in: Capsule())
                            .overlay { Capsule().stroke(ParityTheme.strongSeparator) }
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                    .help(L10n.string("Return to the latest response and follow new messages"))
                    .padding(12)
                }
            }
    }

    /// Goes to the end of the conversation: a sent message, a new request to answer, "Latest response".
    ///
    /// A followed conversation at its end keeps its end in view as it changes (the size-change
    /// anchor), and the stack has laid out the rows there, so its edge is where it says. Otherwise —
    /// the reader went back to earlier turns, or paused following — a lazy stack has only estimated
    /// the rows between, and whatever changed with the message (the turn window moving on, a new
    /// turn) moved its estimate: scrolling to its edge landed past the last row, the conversation
    /// drew nothing, and sometimes it stayed blank until the next update. Scrolling to the last item
    /// has the stack place that row where the view lands; following then keeps the end in view as
    /// the turn grows.
    private func moveToLatest(wasFollowing: Bool, animation: Animation? = nil) {
        onReturnToLatest?()
        continuedScroll.end()
        withAnimation(animation) {
            if wasFollowing && state.isNearBottom {
                position.scrollTo(edge: .bottom)
            } else if let last = readingItemIDs.last {
                position.scrollTo(id: last, anchor: .bottom)
            } else {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    private func applyRestoration(_ request: TranscriptRestoreRequest?) {
        if request != nil {
            blankMonitor?.note("restoring the reading place")
            continuedScroll.end()
        }
        switch request {
        case .anchor(let id):
            state.isFollowing = false
            position.scrollTo(id: id, anchor: .top)
        case .offset(let offset):
            state.isFollowing = false
            position.scrollTo(y: offset)
        case .latest:
            state.isFollowing = true
            position.scrollTo(edge: .bottom)
        case nil:
            // A completed point/ID command must not be reapplied by the next lazy layout pass.
            if !state.isFollowing { position.isPositionedByUser = true }
        }
    }
}
