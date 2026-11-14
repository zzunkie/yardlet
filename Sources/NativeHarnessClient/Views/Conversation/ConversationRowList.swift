import AppKit
import SwiftUI

/// The conversation's rows in an AppKit list (`ConversationRowsView`) that holds the turns' own hosting
/// views (`ConversationTurnHosting`) for the rows in view, in place of the eager SwiftUI stack in a
/// scroll view (`ConversationTimeline.scrollView`). A row's height is kept by its hosting for each width
/// and asked again only for the rows whose turn changed, and scrolling moves the clip view and puts the
/// rows that crossed its edges in or out, without laying out or measuring anything in SwiftUI.
///
/// What it does so far: scrolling, following the latest output (and letting go when the reader
/// scrolls away from the end), bringing earlier turns in at the top as the reader scrolls up to it
/// while the rows in view stay where they are, "Latest response", and going to the latest output
/// on a new turn or a new request to answer. Find, saved reading places, the rail's turns, places
/// another view asks for and history results do not move this view yet.
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
    /// "Latest response" asks for the end through it.
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
}

/// The list's scroll view, which tells the reader's own scrolling (the wheel, a trackpad, the
/// scroller, the keyboard) from the view moving for anything else.
final class ConversationRowListScrollView: NSScrollView {
    /// The reader started a new scroll.
    var onReaderBeganScrolling: () -> Void = {}
    private var isLiveScrolling = false
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

    // The keyboard's scrolling.
    override func scrollPageUp(_ sender: Any?) { readerMoved(); super.scrollPageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { readerMoved(); super.scrollPageDown(sender) }
    override func scrollLineUp(_ sender: Any?) { readerMoved(); super.scrollLineUp(sender) }
    override func scrollLineDown(_ sender: Any?) { readerMoved(); super.scrollLineDown(sender) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { readerMoved(); super.scrollToBeginningOfDocument(sender) }
    override func scrollToEndOfDocument(_ sender: Any?) { readerMoved(); super.scrollToEndOfDocument(sender) }
}

/// A row's view: the turn's hosting view, placed in the conversation's column below the gap before it.
/// It places the turn as its frame or gaps change, without asking the window for a layout pass.
private final class ConversationRowCell: ConversationPressSurface {
    private(set) var content: NSView?
    /// The space above the turn, and below it (the conversation's end, under the last row).
    var gap: CGFloat = 0 {
        didSet { if gap != oldValue { placeContent() } }
    }
    var bottom: CGFloat = 0 {
        didSet { if bottom != oldValue { placeContent() } }
    }

    func show(_ view: NSView) {
        guard content !== view else { return }
        detach()
        view.removeFromSuperview()
        content = view
        addSubview(view)
        placeContent()
    }

    func detach() {
        if let content, content.superview === self { content.removeFromSuperview() }
        content = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeContent()
    }

    private func placeContent() {
        guard let content else { return }
        let width = ConversationRowListController.columnWidth(in: bounds.width)
        let frame = CGRect(x: ((bounds.width - width) / 2).rounded(.down), y: gap, width: width,
                           height: max(0, bounds.height - gap - bottom))
        if content.frame != frame { content.frame = frame }
    }
}

/// The conversation's rows stacked by their heights, the scroll view's document. It finds the rows
/// in a rect from their tops and holds only the views of the rows it is told to show. Scrolling asks
/// nothing of it but that: a table view marked itself for layout at every frame of a scroll, to lay
/// its rows out, and the window's SwiftUI laid the whole window out again with it.
private final class ConversationRowsView: NSView {
    /// Each row's top, and the end of the last row.
    private(set) var tops: [CGFloat] = [0]

    override var isFlipped: Bool { true }
    // It draws nothing: the conversation's canvas is behind it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    var rowCount: Int { tops.count - 1 }

    /// Stacks rows of these heights; the view is as tall as they are. Only the rows from `first` on
    /// moved: a row's height places the rows below it, so a streaming last row restacks itself alone.
    func setHeights(_ heights: [CGFloat], from first: Int = 0) {
        let start = tops.count == heights.count + 1 ? min(max(0, first), heights.count) : 0
        if tops.count != heights.count + 1 { tops = [CGFloat](repeating: 0, count: heights.count + 1) }
        for index in start..<heights.count { tops[index + 1] = tops[index] + heights[index] }
        let end = tops[heights.count]
        if frame.height != end { setFrameSize(NSSize(width: frame.width, height: end)) }
    }

    func rect(ofRow row: Int) -> CGRect {
        guard row >= 0, row < rowCount else { return .zero }
        return CGRect(x: 0, y: tops[row], width: bounds.width, height: tops[row + 1] - tops[row])
    }

    /// The rows that cross `rect`.
    func rows(in rect: CGRect) -> Range<Int> {
        guard rowCount > 0, rect.height > 0 else { return 0..<0 }
        // The first row whose end is below the rect's top, and the first whose top is at its bottom.
        let first = firstIndex { tops[$0 + 1] > rect.minY }
        let end = firstIndex { tops[$0] >= rect.maxY }
        return first..<max(first, end)
    }

    /// The first row for which `isPast`, which turns from false to true down the rows, holds.
    private func firstIndex(where isPast: (Int) -> Bool) -> Int {
        var low = 0, high = rowCount
        while low < high {
            let middle = (low + high) / 2
            if isPast(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

@MainActor
final class ConversationRowListController: NSObject {
    let scrollView = ConversationRowListScrollView()
    private let rowsView = ConversationRowsView()
    private var parent: ConversationRowList?
    private var environment = EnvironmentValues()
    private var rows: [ConversationTurnHost] = []
    private var ids: [String] = [] {
        didSet { if ids != oldValue { rowIndex = Dictionary(ids.enumerated().map { ($1, $0) }) { first, _ in first } } }
    }
    /// Each row's place in `ids`: a streamed line finds its row without a pass over the list.
    private var rowIndex: [String: Int] = [:]
    /// The turns' hostings this list shows, by row ID; the render state keeps them for the task.
    private var hostings: [String: ConversationTurnHosting] = [:]
    /// The rows' heights, as the rows view stacks them.
    private var heights: [CGFloat] = []
    /// The views of the rows in view, by row ID, and the ones free for the next rows.
    private var cells: [String: ConversationRowCell] = [:]
    private var freeCells: [ConversationRowCell] = []
    private var lastLatestRequestID: String?
    /// The timeline last handed over, whose rows the rows waiting to come in are taken from.
    private var lastTimeline: ConversationRowList?
    /// Rows that arrived before the first one, waiting to be measured, and those measured at
    /// `measuredWidth`.
    private var staged: [String] = []
    private var measured: Set<String> = []
    private var measuredWidth: CGFloat = 0
    private var stagingScheduled = false
    private var lastPendingRequestIDs: Set<String> = []
    private var hasStarted = false
    private var topLoading = TranscriptTopLoading()
    /// The view is moving for this controller, not for the reader.
    private var adjusting = 0
    private var lastWidth: CGFloat = 0
    private var followScheduled = false
    /// SwiftUI is updating the list: what this controller writes to the conversation's state waits
    /// for the update to end.
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification,
                           object: scrollView.contentView)
        scrollView.onReaderBeganScrolling = { [weak self] in self?.topLoading.readerBeganScrolling() }
    }

    // MARK: - Updates

    func update(_ timeline: ConversationRowList, environment: EnvironmentValues) {
        parent = timeline
        self.environment = environment
        isUpdating = true
        defer { isUpdating = false }
        let allIDs = timeline.rows.map(\.turn.id)
        let oldIDs = ids
        let following = timeline.scrollState.isFollowing
        lastTimeline = timeline
        // Rows that arrived before the first one (earlier turns) wait out of the list until each is
        // measured (`stageNext`), and then go in together.
        let rowsShown = shownRows(of: timeline.rows, following: following)
        let newIDs = rowsShown.map(\.turn.id)

        // Read from the layout before the change: the rows in view now, and where the first one is.
        let arrived = !following && TranscriptTopLoading.earlierItemsArrived(from: oldIDs, to: newIDs)
        let place = arrived ? placeToKeep(in: Set(newIDs)) : nil

        rows = rowsShown
        ids = newIDs
        let kept = Set(allIDs)
        for id in hostings.keys where !kept.contains(id) {
            hostings[id]?.onResize = {}
            hostings[id] = nil
        }
        // Each row's turn draws again only when it changed (`ConversationTurnHosting.show`).
        for (index, host) in rows.enumerated() {
            hosting(at: index).show(host, environment: environment)
        }
        restack()

        if let place, let row = rowIndex[place.id] {
            scroll(toY: rowsView.rect(ofRow: row).minY - place.top)
        }

        if !hasStarted {
            hasStarted = true
            lastLatestRequestID = timeline.latestRequestID
            lastPendingRequestIDs = timeline.pendingRequestIDs
            afterUpdate { [weak self] in
                timeline.readingTracker.start(record: nil, itemIDs: newIDs)
                self?.setFollowing(true)
            }
            scrollToBottomSoon()
            return
        }
        afterUpdate { timeline.readingTracker.updateItems(newIDs) }
        if timeline.latestRequestID != lastLatestRequestID {
            lastLatestRequestID = timeline.latestRequestID
            followLatest()
        }
        if timeline.pendingRequestIDs != lastPendingRequestIDs {
            var state = timeline.scrollState
            let moves = state.pendingRequestsChanged(from: lastPendingRequestIDs, to: timeline.pendingRequestIDs)
            lastPendingRequestIDs = timeline.pendingRequestIDs
            if moves {
                writeState(state)
                afterUpdate { timeline.readingTracker.followLatest() }
                scrollToBottomSoon()
            }
        }
        if isFollowing { scrollToBottomSoon() }
    }

    func dismantle() {
        for cell in cells.values {
            cell.detach()
            cell.removeFromSuperview()
        }
        cells = [:]
        freeCells = []
        for hosting in hostings.values { hosting.onResize = {} }
        hostings = [:]
        parent?.readingTracker.hide()
        parent = nil
        lastTimeline = nil
        staged = []
    }

    /// The rows to show of `all`. Rows that arrived before the first row shown come in only once each is
    /// measured, one a display cycle out of sight, so they go in together: put in as each was measured,
    /// the list grew a row at a time and the scroller's knob shrank in steps under the reader's scroll.
    private func shownRows(of all: [ConversationTurnHost], following: Bool) -> [ConversationTurnHost] {
        let allIDs = all.map(\.turn.id)
        guard hasStarted, !following, !ids.isEmpty, allIDs.count > ids.count,
              Array(allIDs.suffix(ids.count)) == ids else {
            staged = []
            return all
        }
        let arrived = all.prefix(allIDs.count - ids.count)
        let width = Self.columnWidth(in: rowsView.bounds.width)
        if width != measuredWidth { measured = []; measuredWidth = width }
        staged = arrived.map(\.turn.id).filter { !measured.contains($0) }
        guard staged.isEmpty || width < 80 else {
            stageNext()
            return Array(all.suffix(ids.count))
        }
        staged = []
        return all
    }

    /// Measures the next row waiting to come in, out of sight, at the next display cycle; once none
    /// is left, puts them all in.
    private func stageNext() {
        guard !stagingScheduled else { return }
        stagingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }
            stagingScheduled = false
            guard let timeline = lastTimeline, let id = staged.first else { return }
            staged.removeFirst()
            if let host = timeline.rows.first(where: { $0.turn.id == id }) {
                let hosting = hosting(for: id)
                hosting.show(host, environment: environment)
                _ = hosting.size(forWidth: measuredWidth)
                measured.insert(id)
            }
            if staged.isEmpty { update(timeline, environment: environment) } else { stageNext() }
        }
    }

    /// Goes to the end and follows it: a new turn, "Latest response".
    func followLatest() {
        afterUpdate { [weak self] in
            self?.parent?.onReturnToLatest()
            self?.parent?.readingTracker.followLatest()
            self?.setFollowing(true)
        }
        scrollToBottomSoon()
    }

    /// Runs `body` now, or once SwiftUI's update of the list has ended when it is in one.
    private func afterUpdate(_ body: @escaping @MainActor () -> Void) {
        guard isUpdating else { return body() }
        DispatchQueue.main.async { body() }
    }

    // MARK: - Rows

    private func hosting(at index: Int) -> ConversationTurnHosting {
        hosting(for: ids[index])
    }

    private func hosting(for id: String) -> ConversationTurnHosting {
        if let hosting = hostings[id] { return hosting }
        let hosting = parent?.renderState.hosting(for: id) ?? ConversationTurnHosting(turnID: id)
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
        index == ids.count - 1 ? ConversationLayout.bottomPadding : 0
    }

    /// A row's height: its turn's at the column's width, which the turn's hosting keeps for each width
    /// until the turn changes, with the gaps around it.
    private func rowHeight(_ index: Int) -> CGFloat {
        let width = Self.columnWidth(in: rowsView.bounds.width)
        guard width >= 80 else { return max(1, gap(index) + bottom(index)) }
        return gap(index) + hosting(at: index).size(forWidth: width).height + bottom(index)
    }

    /// Stacks the rows at their heights again and shows the rows in view. Only a turn that changed
    /// is measured again; the others' heights are kept by their hostings, and only the rows below the
    /// first that changed move.
    private func restack() {
        let new = ids.indices.map(rowHeight)
        let first = new.count == heights.count ? new.indices.first { new[$0] != heights[$0] } ?? new.count : 0
        heights = new
        rowsView.setHeights(heights, from: first)
        tile()
    }

    /// Puts the views of the rows in view in their places, and takes out the views of the rows that
    /// left it. A row out of view takes its turn out of the window: nothing it holds lays out, tracks
    /// the pointer or answers hit tests until it comes back. It runs at every frame of a scroll, and
    /// costs the rows that crossed the view's edges.
    private func tile() {
        let visible = visibleRows()
        var shown = Set<String>()
        for row in visible { shown.insert(ids[row]) }
        for (id, cell) in cells where !shown.contains(id) {
            cell.detach()
            cell.removeFromSuperview()
            cells[id] = nil
            freeCells.append(cell)
        }
        for row in visible {
            let id = ids[row]
            let cell = cells[id] ?? {
                let cell = freeCells.popLast() ?? ConversationRowCell()
                cells[id] = cell
                return cell
            }()
            cell.gap = gap(row)
            cell.bottom = bottom(row)
            let frame = rowsView.rect(ofRow: row)
            if cell.frame != frame { cell.frame = frame }
            if cell.content == nil {
                cell.show(hosting(at: row).controller.view)
                rowsView.addSubview(cell)
            }
        }
    }

    /// The rows in view.
    private func visibleRows() -> Range<Int> {
        let range = rowsView.rows(in: scrollView.contentView.bounds)
        return range.clamped(to: 0..<ids.count)
    }

    /// A turn grew or shrank on its own: a fold opened, a line streamed.
    private func rowResized(_ id: String) {
        guard let index = rowIndex[id], index < heights.count else { return }
        let height = rowHeight(index)
        guard heights[index] != height else { return }
        let first = isFollowing ? nil : placeToKeep()
        heights[index] = height
        rowsView.setHeights(heights, from: index)
        tile()
        if isFollowing {
            scrollToBottomSoon()
        } else if let first, let row = rowIndex[first.id], row > index {
            // A row above the one being read changed: the one being read stays where it is.
            scroll(toY: rowsView.rect(ofRow: row).minY - first.top)
        }
    }

    // MARK: - Scrolling

    private var isFollowing: Bool { parent?.scrollState.isFollowing ?? true }

    private func setFollowing(_ following: Bool) {
        guard var state = parent?.scrollState, state.isFollowing != following else { return }
        state.isFollowing = following
        writeState(state)
    }

    /// Writes the follow state only when it changed: each write draws the conversation's view again.
    private func writeState(_ state: TranscriptScrollFollowState) {
        guard let parent, parent.scrollState != state else { return }
        afterUpdate { parent.$scrollState.wrappedValue = state }
    }

    private struct Metrics: Equatable {
        var offset: CGFloat
        var height: CGFloat
        var viewport: CGSize
        var distance: CGFloat { max(0, height - offset - viewport.height) }
    }

    private var metrics: Metrics {
        let visible = scrollView.contentView.bounds
        return Metrics(offset: visible.minY, height: rowsView.frame.height, viewport: visible.size)
    }

    private var lastMetrics: Metrics?

    @objc private func boundsChanged() {
        let new = metrics
        defer { lastMetrics = new }
        tile()
        guard let parent, new.viewport.width >= 80, new.viewport.height >= 60 else { return }
        let readerScrolled = adjusting == 0 && scrollView.isReaderScrolling
        // The view moved over rows that stayed as they were, and not for this list: the reader, or
        // something brought into view for them (find's match, an accessibility scroll). As for the
        // stack (`TranscriptScrollMetrics.isUserMovement`), that decides whether to follow the latest
        // output; otherwise the next row measured again took the view back to the end.
        let moved = adjusting == 0 && lastMetrics.map {
            $0.height == new.height && $0.viewport == new.viewport && abs($0.offset - new.offset) > 1
        } ?? false
        let userDriven = readerScrolled || moved
        var state = parent.scrollState
        state.observe(distance: new.distance, userDriven: userDriven)
        writeState(state)
        parent.readingTracker.observe(offset: new.offset, height: new.height, viewport: new.viewport,
                                      followsLatest: state.isFollowing, userDriven: userDriven)
        // Earlier turns are asked for two screens before the top, so they are in place by the time the
        // reader's scroll gets there instead of arriving once it has hit the top and bounced.
        let ahead = 2 * new.viewport.height
        if let loadEarlier = parent.loadEarlier,
           topLoading.shouldLoad(offset: max(0, new.offset - ahead), userDriven: readerScrolled, key: parent.earlierKey) {
            // Not inside the scroll's own notification: the turns that arrive change the list.
            DispatchQueue.main.async { loadEarlier() }
        }
    }

    @objc private func frameChanged() {
        let width = scrollView.contentView.bounds.width
        guard width != lastWidth else {
            if isFollowing { scrollToBottomSoon() }
            return
        }
        lastWidth = width
        // Every row's height is by width; a hosting keeps the heights it was measured at.
        let place = isFollowing ? nil : placeToKeep()
        rowsView.setFrameSize(NSSize(width: width, height: rowsView.frame.height))
        restack()
        if let place, let row = rowIndex[place.id] {
            scroll(toY: rowsView.rect(ofRow: row).minY - place.top)
        } else if isFollowing {
            scrollToBottomSoon()
        }
    }

    /// The first row in view that `kept` still holds (every row when nil), and how far its top is
    /// below the view's top.
    private func placeToKeep(in kept: Set<String>? = nil) -> (id: String, top: CGFloat)? {
        let visible = scrollView.contentView.bounds
        for row in visibleRows() where kept?.contains(ids[row]) ?? true {
            return (ids[row], rowsView.rect(ofRow: row).minY - visible.minY)
        }
        return nil
    }

    /// Goes to the end once the list has laid out what this update changed.
    private func scrollToBottomSoon() {
        scrollToBottom()
        guard !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            followScheduled = false
            if isFollowing { scrollToBottom() }
        }
    }

    private func scrollToBottom() {
        scroll(toY: rowsView.frame.height - scrollView.contentView.bounds.height)
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let target = min(max(0, y), max(0, rowsView.frame.height - clip.bounds.height))
        guard abs(clip.bounds.minY - target) >= 0.5 else { return }
        adjusting += 1
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        adjusting -= 1
    }
}
