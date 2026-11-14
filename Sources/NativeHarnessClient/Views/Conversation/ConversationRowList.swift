import AppKit
import SwiftUI

/// The conversation's rows in an AppKit list (`ConversationRowsView`) that holds the turns' own hosting
/// views (`ConversationTurnHosting`) for the rows in view, in place of the eager SwiftUI stack in a
/// scroll view (`ConversationTimeline.scrollView`). A row's height is kept by its hosting for each width
/// and asked again only for the rows whose turn changed, and scrolling moves the clip view and puts the
/// rows that crossed its edges in or out, without laying out or measuring anything in SwiftUI.
///
/// It scrolls, follows the latest output (and lets go when the reader scrolls away from the end), brings
/// earlier turns in at the top as the reader scrolls up to it while the rows in view stay where they are,
/// offers "Latest response", goes to the latest output on a new turn or a new request to answer, and goes
/// to the places the conversation is asked for (`ConversationRowTarget`) and the saved place being read
/// (`TranscriptReadingTracker`), as soon as their row is in the list.
enum ConversationRowListSwitch {
    /// Turns the row list on while it and the stack both exist: `defaults write com.zzunkie.yardlet
    /// YardletConversationRowList -bool true` (or the launch argument `-YardletConversationRowList YES`),
    /// or `YARDLET_CONVERSATION_ROW_LIST=1` in the environment, as tests and the bench do. Read once, at
    /// launch. It is not a setting: no Settings pane or settings tool shows it, and it goes away with
    /// the stack once the row list draws every conversation.
    static let defaultsKey = "YardletConversationRowList"
    static let isOn = UserDefaults.standard.bool(forKey: defaultsKey)
        || ProcessInfo.processInfo.environment["YARDLET_CONVERSATION_ROW_LIST"] == "1"
}

/// The list drawing a conversation's rows, while `ConversationRowListSwitch` is on.
struct ConversationRowList: NSViewRepresentable {
    /// The rows drawn, in order: a whole turn or a part of one (`ConversationTurnRows`).
    let rows: [ConversationTurnHost]
    let renderState: ConversationRenderState
    @Binding var scrollState: TranscriptScrollFollowState
    let latestRequestID: String?
    let pendingRequestIDs: Set<String>
    let readingTracker: TranscriptReadingTracker
    /// Brings earlier turns in (`TranscriptTopLoading`); nil where there are none.
    let loadEarlier: (() -> Void)?
    let earlierKey: String?
    let onReturnToLatest: () -> Void
    /// A place the conversation was asked to go to: the rail's turn, find's match, a history result,
    /// another view's call.
    let target: ConversationRowTarget?
    /// "Latest response" and the reading tracker's restorations go through it.
    let scroller: ConversationRowListScroller

    func makeCoordinator() -> ConversationRowListController { ConversationRowListController() }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        scroller.controller = controller
        return controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        scroller.controller = context.coordinator
        context.coordinator.update(self, environment: context.environment)
    }

    /// The size it is offered, without measuring the list: rows coming into view and leaving it mark
    /// the window for layout, and asked its fitting size each time, the scroll view's constraints
    /// solved its whole subtree.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: ConversationRowListController) {
        coordinator.dismantle()
    }
}

/// Lets the conversation's SwiftUI controls move its list.
@MainActor
final class ConversationRowListScroller {
    fileprivate weak var controller: ConversationRowListController?

    init() {}

    /// Goes to the end of the conversation and follows it.
    func scrollToLatest() {
        controller?.followLatest()
    }

    /// Goes to the place the reading tracker asks for (`TranscriptReadingTracker.request`).
    func restore(_ request: TranscriptRestoreRequest?) {
        controller?.restore(request)
    }
}

/// A row the conversation was asked to bring into view, and where: the rail's turn, find's match and a
/// history result in the middle, a call another view asked for at the top. A new `token` asks again.
struct ConversationRowTarget: Equatable {
    enum Placement: Equatable {
        case center
        case top
    }

    let rowID: String
    let placement: Placement
    var animated = false
    let token: Int
}

/// The list's scroll view, which tells the reader's own scrolling (the wheel, a trackpad, the
/// scroller, the keyboard) from the view moving for anything else.
final class ConversationRowListScrollView: NSScrollView {
    /// The reader started a new scroll.
    var onReaderBeganScrolling: () -> Void = {}
    /// The reader's gesture, or their drag of the scroller, ended with its momentum.
    var onReaderEndedScrolling: () -> Void = {}
    /// A trackpad's gesture or a drag of the scroller is under way, momentum included.
    private(set) var isLiveScrolling = false
    private var lastReaderMovement: TimeInterval = 0
    private var wheelMonitor: Any?
    /// Whether the scroll gesture under way scrolls the conversation though it started over a code
    /// block or a table (see `handsOn`); nil until its first movement says which way it goes.
    private var takesGesture: Bool?

    /// The reader's scrolling moved, or may move, the view now.
    var isReaderScrolling: Bool {
        isLiveScrolling || ProcessInfo.processInfo.systemUptime - lastReaderMovement < 0.2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let handsOn = MainActor.assumeIsolated { event.window !== self.window || self.handsOn(event) }
            return handsOn ? event : nil
        }
    }

    /// Code blocks and tables scroll sideways in SwiftUI scroll views of their own, which take every
    /// scroll over them: under a SwiftUI scroll view SwiftUI hands the vertical part on, under this one
    /// nothing does, and the conversation stopped scrolling wherever the pointer crossed a code block.
    /// A gesture over one that goes mostly up or down is this view's from its first movement to the
    /// end of its momentum; one that goes sideways stays the code block's (`handsOn`).
    /// Returns whether the event goes on to the view under the pointer. The application's event
    /// monitor asks it of every scroll event in this view's window before the window has it.
    func handsOn(_ event: NSEvent) -> Bool {
        guard let window, let document = documentView else { return true }
        let isNewGesture = event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if isNewGesture { takesGesture = nil }
        if takesGesture == true {
            scrollWheel(with: event)
            // The code block saw the gesture begin: it sees it end.
            return event.phase == .ended || event.phase == .cancelled
        }
        guard takesGesture == nil, bounds.contains(convert(event.locationInWindow, from: nil)),
              let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: document),
              let inner = hit.enclosingScrollView, inner !== self else { return true }
        if event.phase == .began {
            // Both hear it begin; the first movement decides whose gesture it is.
            scrollWheel(with: event)
            return true
        }
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return true }
        takesGesture = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        guard takesGesture == true else { return true }
        scrollWheel(with: event)
        return false
    }

    @objc private func liveScrollStarted() {
        isLiveScrolling = true
        onReaderBeganScrolling()
    }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        readerMoved()
        onReaderEndedScrolling()
    }

    private func readerMoved() {
        lastReaderMovement = ProcessInfo.processInfo.systemUptime
    }

    override func scrollWheel(with event: NSEvent) {
        // A wheel without phases (a mouse) starts a scroll at each notch that follows a pause.
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty && !isReaderScrolling) {
            onReaderBeganScrolling()
        }
        readerMoved()
        super.scrollWheel(with: event)
    }

    // The keyboard's scrolling, which a text in the conversation hands on (`TranscriptProseTextView`):
    // the reader's own, as the wheel's is. NSScrollView answers only `pageUp:` and `pageDown:` itself.
    override func scrollPageUp(_ sender: Any?) { readerScroll(by: -page) }
    override func scrollPageDown(_ sender: Any?) { readerScroll(by: page) }
    override func pageUp(_ sender: Any?) { readerScroll(by: -page) }
    override func pageDown(_ sender: Any?) { readerScroll(by: page) }
    override func scrollLineUp(_ sender: Any?) { readerScroll(by: -verticalLineScroll) }
    override func scrollLineDown(_ sender: Any?) { readerScroll(by: verticalLineScroll) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { readerScroll(toY: 0) }
    override func scrollToEndOfDocument(_ sender: Any?) { readerScroll(toY: .greatestFiniteMagnitude) }

    /// A page, less what stays in view of the one before.
    private var page: CGFloat { max(0, contentView.bounds.height - verticalPageScroll) }

    private func readerScroll(by delta: CGFloat) {
        readerScroll(toY: contentView.bounds.minY + delta)
    }

    private func readerScroll(toY y: CGFloat) {
        guard let document = documentView else { return }
        if !isReaderScrolling { onReaderBeganScrolling() }
        readerMoved()
        let target = min(max(0, y), max(0, document.frame.height - contentView.bounds.height))
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: target))
        reflectScrolledClipView(contentView)
    }
}

/// A row's view: the turn's hosting view, in the conversation's column, as tall as the turn. Presses the
/// turn's content hands on go on to the list's document (`ConversationRowsView`), which takes them for
/// the conversation's selection; the cell is not a press surface of its own, or the document would
/// follow a press the cell had followed to its release, and wait for another.
final class ConversationRowCell: NSView {
    private(set) var content: NSView?
    /// The row it draws.
    var rowID: String?

    override var isFlipped: Bool { true }

    func show(_ view: NSView) {
        guard content !== view else { return }
        detach()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        content = view
        addSubview(view)
    }

    func detach() {
        if let content, content.superview === self { content.removeFromSuperview() }
        content = nil
    }
}

/// The scroll view's document: as tall as the conversation's rows, holding the views of the rows near
/// the viewport. Its margins and the space between the rows take presses for the conversation's
/// selection, as the stack's backdrop does. Scrolling asks nothing of it: a table view marked itself
/// for layout at every frame of a scroll, to lay its rows out, and the window's SwiftUI laid the whole
/// window out again with it.
private final class ConversationRowsView: ConversationPressSurface {
    // It draws nothing: the conversation's canvas is behind it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}

/// Whether an assistive app that reads the whole conversation is on: VoiceOver or Switch Control, which
/// move through every element in the window and expect the conversation's turns in its accessibility
/// tree. It is not `accessibilityEnabled`: a window manager or another app that reads the window through
/// accessibility turns that on too, and the conversation would then lose the rows it leaves out.
@MainActor
enum ConversationAssistiveReading {
    /// Posted on the main thread when either app is turned on or off.
    static let didChange = Notification.Name("ConversationAssistiveReadingDidChange")
    /// Reads it now; a test can stand in for the apps.
    static var isOn: () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }

    private static var observations: [NSKeyValueObservation] = []

    /// Posts `didChange` when either app is turned on or off, from the first call on.
    static func watch() {
        guard observations.isEmpty else { return }
        let changed: @Sendable (NSWorkspace, NSKeyValueObservedChange<Bool>) -> Void = { _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
        }
        observations = [
            NSWorkspace.shared.observe(\.isVoiceOverEnabled, changeHandler: changed),
            NSWorkspace.shared.observe(\.isSwitchControlEnabled, changeHandler: changed)
        ]
    }
}

/// Keeps the list's rows where `ConversationRowGeometry` places them and the viewport at the place read
/// (its anchor): every change to the rows goes through `change`, which reads the anchor first and puts
/// the viewport back at it in the same turn of the run loop, before anything is drawn. What the reader
/// sees moves only as they scroll or are taken somewhere.
@MainActor
final class ConversationRowListController: NSObject {
    /// How far above and below the viewport, in viewports, rows keep their views in the window: a row
    /// coming into view is laid out a little before it does.
    static let overscan: CGFloat = 1

    let scrollView = ConversationRowListScrollView()
    private let rowsView = ConversationRowsView()
    private var parent: ConversationRowList?
    private var environment = EnvironmentValues()
    private var rows: [ConversationTurnHost] = []
    private var geometry = ConversationRowGeometry()
    /// The turns' hostings this list shows, by row ID; the render state keeps them for the task.
    private var hostings: [String: ConversationTurnHosting] = [:]
    /// The views of the rows near the viewport, by row ID, and the ones free for the next rows.
    private var cells: [String: ConversationRowCell] = [:]
    private var freeCells: [ConversationRowCell] = []
    private var idsInView: [String] = []
    /// VoiceOver or Switch Control is on (`ConversationAssistiveReading`).
    private var readsEveryRow = false
    /// Whether to follow the latest output, and how near the end the reader is: the conversation's
    /// state as this list last wrote or read it. `written` is a write SwiftUI has not handed back yet.
    private var followState = TranscriptScrollFollowState()
    private var written: TranscriptScrollFollowState?
    private var lastLatestRequestID: String?
    private var lastPendingRequestIDs: Set<String> = []
    /// A place asked for whose row is not in the list yet, which the change that brings it in goes to.
    private var pendingPlace: Place?
    private var lastTargetToken: Int?
    private var hasStarted = false
    private var topLoading = TranscriptTopLoading()
    /// The view is moving for this controller, not for the reader.
    private var adjusting = 0
    private var lastSize = CGSize.zero
    /// The viewport and the rows' height when the view last moved.
    private var lastSeen: (visible: CGRect, height: CGFloat)?
    /// What arrived below the end of a followed conversation during the reader's gesture, which the
    /// view does not move under: it is not the reader's distance from the end, and comes into view when
    /// the gesture ends.
    private var arrivedUnderGesture: CGFloat = 0
    /// SwiftUI is updating the list: what this controller writes to the conversation's state waits
    /// for the update to end, and a row resizing waits for the update, which measures every row.
    private var isUpdating = false

    /// The column the turns are drawn in, in a row `width` wide: the conversation's width, inset.
    static func columnWidth(in width: CGFloat) -> CGFloat {
        max(0, min(width, ParityTheme.contentWidth) - 2 * ParityTheme.conversationInset)
    }

    override init() {
        super.init()
        scrollView.documentView = rowsView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        rowsView.setAccessibilityElement(false)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification,
                           object: scrollView.contentView)
        scrollView.onReaderBeganScrolling = { [weak self] in self?.topLoading.readerBeganScrolling() }
        scrollView.onReaderEndedScrolling = { [weak self] in self?.readerEndedScrolling() }
        ConversationAssistiveReading.watch()
        readsEveryRow = ConversationAssistiveReading.isOn()
        center.addObserver(self, selector: #selector(assistiveReadingChanged), name: ConversationAssistiveReading.didChange,
                           object: nil)
    }

    @objc private func assistiveReadingChanged() {
        readsEveryRow = ConversationAssistiveReading.isOn()
        tile()
    }

    /// Where the viewport goes for something other than the reader's scroll.
    private enum Place {
        /// A row's content at the viewport's top or in its middle.
        case row(String, ConversationRowTarget.Placement, animated: Bool)
        case offset(CGFloat)
    }

    // MARK: - Updates

    func update(_ timeline: ConversationRowList, environment: EnvironmentValues) {
        parent = timeline
        timeline.readingTracker.rowFrame = { [weak self] id in self?.contentFrame(ofRowID: id) }
        self.environment = environment
        if let written, timeline.scrollState == written { self.written = nil }
        if written == nil { followState = timeline.scrollState }
        isUpdating = true
        defer { isUpdating = false }
        let ids = timeline.rows.map(\.turn.id)
        if ids != geometry.ids {
            let kept = Set(ids)
            for (id, hosting) in hostings where !kept.contains(id) {
                release(hosting)
                hostings[id] = nil
            }
        }
        rows = timeline.rows
        // Each row's turn draws again only when it changed (`ConversationTurnHosting.show`).
        for (index, host) in rows.enumerated() {
            hosting(for: ids[index]).show(host, environment: environment)
        }
        change { geometry.setRows(ids, heights: ids.indices.map(rowHeight), leads: ids.indices.map(gap)) }
        if let target = timeline.target, target.token != lastTargetToken {
            lastTargetToken = target.token
            go(to: .row(target.rowID, target.placement, animated: target.animated))
        }

        if !hasStarted {
            // Reading starts where the conversation shows (`ConversationTimeline`).
            hasStarted = true
            lastLatestRequestID = timeline.latestRequestID
            lastPendingRequestIDs = timeline.pendingRequestIDs
            return
        }
        if timeline.latestRequestID != lastLatestRequestID {
            lastLatestRequestID = timeline.latestRequestID
            followLatest()
        }
        if timeline.pendingRequestIDs != lastPendingRequestIDs {
            var state = followState
            let moves = state.pendingRequestsChanged(from: lastPendingRequestIDs, to: timeline.pendingRequestIDs)
            lastPendingRequestIDs = timeline.pendingRequestIDs
            if moves {
                writeState(state)
                afterUpdate { timeline.readingTracker.followLatest() }
                scrollToEnd()
            }
        }
    }

    func dismantle() {
        for cell in cells.values {
            cell.detach()
            cell.removeFromSuperview()
        }
        cells = [:]
        freeCells = []
        for hosting in hostings.values { release(hosting) }
        hostings = [:]
        parent?.readingTracker.hide()
        parent?.readingTracker.rowFrame = nil
        parent = nil
    }

    /// Goes to the place the reading tracker asks for: a saved place's row, then the point in it, or the end.
    func restore(_ request: TranscriptRestoreRequest?) {
        switch request {
        case let .anchor(id):
            setFollowing(false)
            go(to: .row(id, .top, animated: false))
        case let .offset(y):
            setFollowing(false)
            go(to: .offset(y))
        case .latest:
            pendingPlace = nil
            setFollowing(true)
            scrollToEnd()
        case nil:
            break
        }
    }

    /// Goes to `place` now, or once its row is in the list.
    private func go(to place: Place) {
        pendingPlace = place
        goToPendingPlace()
    }

    private func goToPendingPlace() {
        guard let place = pendingPlace, scrollView.contentView.bounds.width >= 80 else { return }
        let viewport = scrollView.contentView.bounds.height
        switch place {
        case let .row(id, placement, animated):
            guard let frame = contentFrame(ofRowID: id) else { return }
            pendingPlace = nil
            let y = placement == .center ? frame.midY - viewport / 2 : frame.minY
            scroll(toY: y, animated: animated)
        case let .offset(y):
            pendingPlace = nil
            scroll(toY: y)
        }
    }

    /// Goes to the end and follows it: a new turn, "Latest response".
    func followLatest() {
        afterUpdate { [weak self] in
            self?.parent?.onReturnToLatest()
            self?.parent?.readingTracker.followLatest()
            self?.setFollowing(true)
        }
        var state = followState
        state.isFollowing = true
        followState = state
        pendingPlace = nil
        scrollToEnd()
    }

    /// Runs `body` now, or once SwiftUI's update of the list has ended when it is in one.
    private func afterUpdate(_ body: @escaping @MainActor () -> Void) {
        guard isUpdating else { return body() }
        DispatchQueue.main.async { body() }
    }

    // MARK: - Rows

    /// Lets go of a row's hosting, which the next view of its turn may take.
    private func release(_ hosting: ConversationTurnHosting) {
        hosting.onResize = {}
        if hosting.holder === self { hosting.holder = nil }
    }

    private func hosting(for id: String) -> ConversationTurnHosting {
        if let hosting = hostings[id] { return hosting }
        let hosting = parent?.renderState.hosting(for: id, holder: self) ?? ConversationTurnHosting(turnID: id)
        hosting.onResize = { [weak self] in self?.rowResized(id) }
        hostings[id] = hosting
        return hosting
    }

    /// The space before row `index`: the conversation's top, the space between turns, or the space
    /// between the items of one turn for a part that goes on from the one before.
    private func gap(_ index: Int) -> CGFloat {
        if index == 0 { return ConversationLayout.topPadding }
        return rows[index].part.continuesTurn ? ConversationLayout.itemSpacing : ConversationLayout.turnSpacing
    }

    private func bottom(_ index: Int) -> CGFloat {
        index == rows.count - 1 ? ConversationLayout.bottomPadding : 0
    }

    /// A row's height: its turn's at the column's width, which the turn's hosting keeps for each width
    /// until the turn changes, with the space around it.
    private func rowHeight(_ index: Int) -> CGFloat {
        let width = Self.columnWidth(in: rowsView.bounds.width)
        guard width >= 80 else { return max(1, gap(index) + bottom(index)) }
        return gap(index) + hosting(for: rows[index].turn.id).size(forWidth: width).height + bottom(index)
    }

    /// Where row `id`'s turn is drawn in the list's document, or nil while the row is not in the list.
    private func contentFrame(ofRowID id: String) -> CGRect? {
        guard let index = geometry.index(of: id), index < rows.count, rowsView.bounds.width >= 80 else { return nil }
        return contentFrame(ofRow: index)
    }

    /// Where row `index`'s turn is drawn: in the column, below the space before it.
    private func contentFrame(ofRow index: Int) -> CGRect {
        let width = Self.columnWidth(in: rowsView.bounds.width)
        let top = geometry.top(ofRow: index) + gap(index)
        return CGRect(x: ((rowsView.bounds.width - width) / 2).rounded(.down), y: top, width: width,
                      height: max(0, geometry.bottom(ofRow: index) - bottom(index) - top))
    }

    /// Applies `body`'s change to the rows and puts the viewport back at the place read before it: the
    /// end while following, or the row at the viewport's top, at the same point of it. With `scales`
    /// (a new width), that point is the same share of the row's height.
    private func change(scales: Bool = false, _ body: () -> Void) {
        adjusting += 1
        defer { adjusting -= 1 }
        let clip = scrollView.contentView
        let before = clip.bounds.minY
        let endBefore = geometry.contentHeight
        // The reader's gesture over a followed conversation: what arrives below waits for it to end.
        let holdsForGesture = followState.isFollowing && scrollView.isLiveScrolling
        let anchor = geometry.anchor(offset: before, following: followState.isFollowing && !holdsForGesture)
        body()
        let height = geometry.contentHeight
        if rowsView.frame.height != height { rowsView.setFrameSize(NSSize(width: rowsView.frame.width, height: height)) }
        if holdsForGesture { arrivedUnderGesture += max(0, height - endBefore) }
        scroll(toY: geometry.offset(for: anchor, viewportHeight: clip.bounds.height, scales: scales, fallback: before))
        tile()
        goToPendingPlace()
    }

    /// Puts the views of the rows near the viewport in their places, and takes out the views of the rows
    /// that left it. A row away from the viewport takes its turn out of the window: nothing it holds
    /// lays out, tracks the pointer or answers hit tests until it comes back. It runs at every frame of a
    /// scroll, and costs the rows that crossed the edges.
    ///
    /// Some rows keep their views wherever the viewport is (`heldRows`), and with VoiceOver or Switch
    /// Control on every row does, so the conversation reads to them as it did drawn whole.
    private func tile() {
        let visible = scrollView.contentView.bounds
        let margin = visible.height * Self.overscan
        let near = readsEveryRow ? 0..<geometry.count
            : geometry.rows(from: visible.minY - margin, to: visible.maxY + margin)
        let held = heldRows(besides: near)
        for (id, cell) in cells where !(geometry.index(of: id).map { near.contains($0) || held.contains($0) } ?? false) {
            cell.detach()
            cell.removeFromSuperview()
            cell.rowID = nil
            cells[id] = nil
            freeCells.append(cell)
        }
        for row in near {
            let id = geometry.ids[row]
            let cell = cells[id] ?? {
                let cell = freeCells.popLast() ?? ConversationRowCell()
                cells[id] = cell
                return cell
            }()
            let frame = contentFrame(ofRow: row)
            if cell.frame != frame { cell.frame = frame }
            if cell.content == nil {
                cell.rowID = id
                cell.show(hosting(for: id).controller.view)
                rowsView.addSubview(cell)
            }
        }
        for row in held {
            guard let cell = cells[geometry.ids[row]] else { continue }
            let frame = contentFrame(ofRow: row)
            if cell.frame != frame { cell.frame = frame }
        }
        // The rows in view, which the reading place is read from, told as they change.
        let inView = geometry.rows(from: visible.minY, to: visible.maxY).map { geometry.ids[$0] }
        if inView != idsInView, visible.height >= 60 {
            idsInView = inView
            parent?.readingTracker.updateVisibleItems(inView)
        }
    }

    /// The rows out of `near` whose views stay in the window: the last row, where the running turn and
    /// the requests to answer are; the row the window's first responder is in (a field being typed in,
    /// with its marked text); and every row from the first to the last a selection holds, so a drag
    /// that goes on past the viewport keeps where it started (`ConversationSelection.heldViews`). A row
    /// already out of the window is not brought back for them.
    private func heldRows(besides near: Range<Int>) -> IndexSet {
        var held = IndexSet()
        if !geometry.isEmpty { held.insert(geometry.count - 1) }
        if let responder = scrollView.window?.firstResponder as? NSView, let row = row(holding: responder) {
            held.insert(row)
        }
        let selected = ConversationSelection.heldViews.compactMap(row(holding:))
        if let first = selected.min(), let last = selected.max() { held.insert(integersIn: first...last) }
        held.remove(integersIn: near)
        return held
    }

    /// The row whose view holds `view`, while it is in the list's window.
    private func row(holding view: NSView) -> Int? {
        var current: NSView? = view
        while let candidate = current, candidate !== rowsView {
            if let cell = candidate as? ConversationRowCell { return cell.rowID.flatMap(geometry.index(of:)) }
            current = candidate.superview
        }
        return nil
    }

    /// A turn grew or shrank on its own: a fold opened, a line streamed. Only it and the rows below it move.
    private func rowResized(_ id: String) {
        guard !isUpdating, let index = geometry.index(of: id), index < rows.count else { return }
        let height = rowHeight(index)
        guard geometry.heights[index] != height else { return }
        change { geometry.setHeight(height, ofRow: index) }
    }

    // MARK: - Scrolling

    private func setFollowing(_ following: Bool) {
        guard followState.isFollowing != following else { return }
        var state = followState
        state.isFollowing = following
        writeState(state)
    }

    /// Writes the follow state only when it changed: each write draws the conversation's view again.
    private func writeState(_ state: TranscriptScrollFollowState) {
        guard followState != state || written != nil else { return }
        followState = state
        written = state
        guard let parent else { return }
        afterUpdate { parent.$scrollState.wrappedValue = state }
    }

    @objc private func boundsChanged() {
        tile()
        let visible = scrollView.contentView.bounds
        let height = geometry.contentHeight
        let last = lastSeen
        lastSeen = (visible, height)
        guard let parent, visible.width >= 80, visible.height >= 60 else { return }
        let distance = geometry.distanceFromEnd(offset: visible.minY, viewportHeight: visible.height)
        if distance <= 1 { arrivedUnderGesture = 0 }
        let readerScrolled = adjusting == 0 && scrollView.isReaderScrolling
        // The view moved over rows that stayed as they were, and not for this list: the reader, or
        // something brought into view for them (find's match, an accessibility scroll). As for the
        // stack (`TranscriptScrollMetrics.isUserMovement`), that decides whether to follow the latest
        // output; otherwise the next row measured again took the view back to the end.
        let moved = adjusting == 0 && last.map {
            $0.height == height && $0.visible.size == visible.size && abs($0.visible.minY - visible.minY) > 1
        } ?? false
        let userDriven = readerScrolled || moved
        // A place asked for whose row has not come in yet is given up once the reader goes elsewhere.
        if userDriven { pendingPlace = nil }
        var state = followState
        state.observe(distance: distance - arrivedUnderGesture, userDriven: userDriven)
        if !state.isFollowing { arrivedUnderGesture = 0 }
        writeState(state)
        parent.readingTracker.observe(offset: visible.minY, height: height, viewport: visible.size,
                                      followsLatest: state.isFollowing, userDriven: userDriven)
        // Only the reader's own scrolling up to the top brings earlier turns in, as for the stack
        // (`TranscriptTopLoading`).
        if let loadEarlier = parent.loadEarlier,
           topLoading.shouldLoad(offset: visible.minY, userDriven: readerScrolled, key: parent.earlierKey) {
            // Not inside the scroll's own notification: the turns that arrive change the list.
            DispatchQueue.main.async { loadEarlier() }
        }
    }

    /// The reader's gesture over a followed conversation ended: what arrived under it comes into view,
    /// as following would have brought it.
    private func readerEndedScrolling() {
        defer { arrivedUnderGesture = 0 }
        if followState.isFollowing, arrivedUnderGesture > 0 { scrollToEnd() }
    }

    @objc private func frameChanged() {
        let size = scrollView.contentView.bounds.size
        guard size != lastSize else { return }
        let widthChanged = size.width != lastSize.width
        lastSize = size
        if rowsView.frame.width != size.width {
            rowsView.setFrameSize(NSSize(width: size.width, height: rowsView.frame.height))
        }
        // Every row's height is by width; a hosting keeps the heights it was measured at.
        change(scales: widthChanged) {
            if widthChanged {
                geometry.setRows(geometry.ids, heights: geometry.ids.indices.map(rowHeight), leads: geometry.leads)
            }
        }
    }

    private func scrollToEnd() {
        scroll(toY: geometry.maximumOffset(viewportHeight: scrollView.contentView.bounds.height))
    }

    /// Moves the viewport's top to `y`, kept inside the list; `animated` eases there in ParityMotion's
    /// time unless the person asked for reduced motion. A window not on a display goes there at once: its
    /// animation would not run until it is shown, and the list would wait for it.
    private func scroll(toY y: CGFloat, animated: Bool = false) {
        let clip = scrollView.contentView
        let target = min(max(0, y), geometry.maximumOffset(viewportHeight: clip.bounds.height))
        guard abs(clip.bounds.minY - target) >= 0.5 else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           scrollView.window?.occlusionState.contains(.visible) == true {
            adjusting += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollView.reflectScrolledClipView(clip)
                    self.adjusting -= 1
                }
            }
            return
        }
        adjusting += 1
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        adjusting -= 1
    }
}
