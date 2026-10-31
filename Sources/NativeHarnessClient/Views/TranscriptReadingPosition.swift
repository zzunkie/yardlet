import SwiftUI
import Observation

enum TranscriptRestoreRequest: Equatable {
    case anchor(String)
    case offset(CGFloat)
    case latest
}

/// How a conversation whose IDs can change under the reader reads saved places
/// (`ConversationTimeline`, plan A3.5): a detached Codex snapshot names its turns differently from
/// the thread that replaces it when the task attaches.
struct TranscriptReadingAnchors {
    /// The place reading starts from, chosen once when reading starts.
    let start: () -> TranscriptReadingBookmark
    /// A saved place in the IDs the conversation shows now, or nil when it does not hold it.
    let resolve: (TranscriptReadingBookmark) -> TranscriptReadingBookmark?
}

/// Visible scroll targets choose the bookmark; prefetched rows may retain stale geometry.
/// Viewport-relative frames retain a position within a message when surrounding rows grow.
@MainActor @Observable
final class TranscriptReadingTracker {
    let coordinateSpace = UUID().uuidString
    private(set) var request: TranscriptRestoreRequest?
    private(set) var anchorRevision = 0
    private(set) var visibleAnchorID: String?
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var visibleItemIDs: Set<String>?
    @ObservationIgnored private var itemIDs: [String] = []
    @ObservationIgnored private var record: TranscriptReadingPosition?
    @ObservationIgnored private var pending: TranscriptReadingBookmark?
    /// A saved place the conversation could not show when reading started. It is kept, not
    /// overwritten by following the latest output, until the conversation's IDs change and it can be
    /// shown, or the reader moves.
    @ObservationIgnored private var deferred: TranscriptReadingBookmark?
    @ObservationIgnored private var viewport = CGSize.zero
    @ObservationIgnored private var contentHeight: CGFloat = 0
    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var followsLatest = true
    @ObservationIgnored private var wasHidden = false
    @ObservationIgnored private var hasStarted = false
    /// The bookmark as it was when the conversation left the window in views kept to show again
    /// (`TaskSurfaceHost`), until it shows again.
    @ObservationIgnored private var bookmarkWhenHidden: TranscriptReadingBookmark?
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var anchorAttempts = 0
    @ObservationIgnored private var needsCapture = false
    /// When the reader's own scrolling last moved the view.
    @ObservationIgnored private var readerMovedAt: Date?

    var isRestoring: Bool { pending != nil }

    /// The reader's own scrolling moved the view in the last tenth of a second. A place kept now would
    /// be read from geometry their next movement may already have left behind.
    var isReaderScrolling: Bool {
        readerMovedAt.map { Date().timeIntervalSince($0) < 0.1 } ?? false
    }

    /// - Parameters:
    ///   - bookmark: the place to start from; `record`'s bookmark when nil.
    ///   - resolve: reads a saved place in `itemIDs`. With it, a place the conversation cannot show
    ///     yet is kept (see `deferred`) rather than replaced by the latest output.
    func start(record: TranscriptReadingPosition?, itemIDs: [String],
               startingAt bookmark: TranscriptReadingBookmark? = nil,
               resolve: ((TranscriptReadingBookmark) -> TranscriptReadingBookmark?)? = nil) {
        guard !hasStarted else { return }
        hasStarted = true
        self.record = record
        self.itemIDs = itemIDs
        let saved = bookmark ?? record?.bookmark ?? .init()
        followsLatest = saved.followsLatest
        let target: TranscriptReadingBookmark? = if saved.followsLatest { nil }
            else if let resolve { resolve(saved) } else { saved }
        if let target, let id = target.anchorID, itemIDs.contains(id) {
            pending = target
            request = .anchor(id)
        } else {
            if resolve != nil, !saved.followsLatest { deferred = saved }
            followsLatest = true
            request = .latest
        }
        scheduleGeometry()
    }

    /// The conversation leaves the window, its views kept to show again.
    func hide() {
        guard hasStarted else { return }
        bookmarkWhenHidden = record?.bookmark ?? .init()
    }

    /// Whether the conversation, shown again in the views it kept, goes on from where they are. It
    /// does unless its bookmark moved while it was hidden (another view of the task read on); reading
    /// then starts again from the bookmark (`start`), as it does in new views.
    func resumes(record: TranscriptReadingPosition?) -> Bool {
        guard hasStarted, let hidden = bookmarkWhenHidden else { return false }
        bookmarkWhenHidden = nil
        if record === self.record, (record?.bookmark ?? .init()) == hidden { return true }
        hasStarted = false
        pending = nil
        deferred = nil
        return false
    }

    /// - Parameter resolve: reads a saved place in `ids`. With it, a place kept since reading started,
    ///   or the place being read when the conversation renamed its items, is shown again.
    func updateItems(_ ids: [String], resolve: ((TranscriptReadingBookmark) -> TranscriptReadingBookmark?)? = nil) {
        itemIDs = ids
        let retained = Set(ids)
        frames = frames.filter { retained.contains($0.key) }
        if let resolve {
            if let saved = deferred, let target = resolve(saved), let id = target.anchorID, retained.contains(id) {
                deferred = nil
                restore(target, at: id)
                return
            }
            if !followsLatest, let saved = pending ?? record?.bookmark, !saved.followsLatest,
               let anchor = saved.anchorID, !retained.contains(anchor),
               let target = resolve(saved), let id = target.anchorID, retained.contains(id) {
                restore(target, at: id)
                return
            }
        }
        if let id = pending?.anchorID, !retained.contains(id) { followLatest() }
    }

    func measure(id: String, frame: CGRect?) {
        if let frame, frame.width >= 80, frame.height > 0, frame.minY.isFinite {
            frames[id] = frame
        } else {
            frames.removeValue(forKey: id)
        }
        scheduleGeometry()
    }

    func updateVisibleItems(_ ids: [String]) {
        visibleItemIDs = Set(ids)
        if !followsLatest, pending == nil { needsCapture = true }
        scheduleGeometry()
    }

    func observe(offset: CGFloat, height: CGFloat, viewport newViewport: CGSize,
                 followsLatest: Bool, userDriven: Bool) {
        guard newViewport.width >= 80, newViewport.height >= 60, height > 0 else {
            wasHidden = true
            return
        }
        let reflowed = viewport != .zero && (viewport != newViewport || wasHidden)
        viewport = newViewport
        contentHeight = height
        self.offset = offset
        self.followsLatest = followsLatest
        wasHidden = false
        if userDriven {
            readerMovedAt = Date()
            cancelRestoration()
            needsCapture = true
            deferred = nil
        }
        if pending == nil, reflowed, !followsLatest, !userDriven,
           let saved = record?.bookmark, !saved.followsLatest,
           let id = saved.anchorID, itemIDs.contains(id) {
            pending = saved
            anchorAttempts = 0
            if frames[id] == nil { request = .anchor(id) }
        }
        scheduleGeometry()
    }

    /// Called after a geometry transaction, when row and scroll callbacks agree. Keeping this
    /// deterministic also lets tests cover lazy measurement, reflow and interrupted restoration.
    func settleGeometry() {
        guard hasStarted, !wasHidden, viewport.width >= 80, viewport.height >= 60 else { return }
        if let saved = pending, let id = saved.anchorID, let frame = frames[id] {
            let fraction = saved.fraction.isFinite ? min(max(-1, saved.fraction), 1) : 0
            let delta = frame.minY + frame.height * fraction
            let desired = offset + delta
            let maximum = max(0, contentHeight - viewport.height)
            let target = min(max(0, desired), maximum)
            let knownBoundary = (desired <= 0 && id == itemIDs.first && frame.minY >= 0)
                || (desired >= maximum && id == itemIDs.last && frame.maxY <= viewport.height)
            // Lazy layout may temporarily report a document shorter than the visible message.
            // A clamped offset is not proof that the saved location has actually been reached.
            if abs(desired - target) >= 2, !knownBoundary {
                locateAnchor(id)
            } else if abs(target - offset) < 2 {
                pending = nil
                request = nil
                record?.bookmark = saved
                visibleAnchorID = id
            } else {
                request = .offset(target)
            }
            return
        }
        if let id = pending?.anchorID {
            // Lazy rows can change the estimated document height while locating a target.
            // Reissue the ID after that layout transaction until its real frame is available.
            locateAnchor(id)
            return
        }
        if followsLatest {
            if deferred == nil { record?.bookmark = .init() }
            visibleAnchorID = itemIDs.last
            needsCapture = false
        } else if needsCapture, let bookmark = Self.bookmark(offset: 0, frames: frames,
            itemIDs: itemIDs.filter { visibleItemIDs?.contains($0) ?? true }) {
            record?.bookmark = bookmark
            visibleAnchorID = bookmark.anchorID
            needsCapture = false
        }
    }

    /// What keeps the reader's place when earlier items arrive above it: the first item in view at
    /// the last layout, and the anchor at which `scrollTo(id:anchor:)` puts it back exactly where it
    /// was in the viewport. A scroll anchor lines up the same point of the item and of the viewport,
    /// so an item `height` tall whose top was `y` points into a viewport `H` tall goes back with
    /// `y / (H - height)`; an item exactly as tall as the viewport cannot say where it was, and the
    /// next one in view is used instead.
    func placeToKeep() -> (id: String, anchor: UnitPoint)? {
        guard viewport.height >= 60 else { return nil }
        for id in itemIDs where visibleItemIDs?.contains(id) ?? true {
            guard let frame = frames[id], frame.maxY > 0 else { continue }
            let free = viewport.height - frame.height
            guard abs(free) >= 1 else { continue }
            return (id, UnitPoint(x: 0.5, y: frame.minY / free))
        }
        return nil
    }

    func cancelRestoration() {
        pending = nil
        request = nil
        anchorAttempts = 0
    }

    func followLatest() {
        pending = nil
        deferred = nil
        followsLatest = true
        record?.bookmark = .init()
        visibleAnchorID = itemIDs.last
        request = .latest
    }

    static func bookmark(offset: CGFloat, frames: [String: CGRect], itemIDs: [String]) -> TranscriptReadingBookmark? {
        let measured = itemIDs.compactMap { id in frames[id].map { (id, $0) } }
        guard let (id, frame) = measured.first(where: { $0.1.maxY > offset }) ?? measured.last,
              frame.height > 0 else { return nil }
        // A negative fraction preserves the short gap before the first visible message.
        let fraction = min(max(-1, (offset - frame.minY) / frame.height), 1)
        return TranscriptReadingBookmark(anchorID: id,
            fraction: (fraction * 1_000_000).rounded() / 1_000_000, followsLatest: false)
    }

    private func restore(_ target: TranscriptReadingBookmark, at id: String) {
        pending = target
        followsLatest = false
        anchorAttempts = 0
        request = .anchor(id)
        anchorRevision += 1
    }

    private func locateAnchor(_ id: String) {
        guard anchorAttempts < 8 else {
            // Keep the saved bookmark, but never trap manual navigation behind a stale target.
            cancelRestoration()
            return
        }
        anchorAttempts += 1
        request = .anchor(id)
        anchorRevision += 1
    }

    private func scheduleGeometry() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.settleGeometry()
        }
    }
}

extension View {
    func transcriptReadingAnchor(_ id: String, tracker: TranscriptReadingTracker) -> some View {
        self.id(id)
            .onGeometryChange(for: CGRect?.self) { geometry in
                let frame = geometry.frame(in: .named(tracker.coordinateSpace))
                // Limit notifications to the visible region and a small prefetch margin.
                return frame.maxY >= 0 && frame.minY <= 1_600 ? frame : nil
            } action: { _, frame in tracker.measure(id: id, frame: frame) }
            // A lazy row can leave the view tree without publishing offscreen geometry.
            // Its last visible frame must not compete with the message now being read.
            .onDisappear { tracker.measure(id: id, frame: nil) }
    }
}
