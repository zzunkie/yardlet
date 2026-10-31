import AppKit
import Observation
import SwiftUI

/// What the reply list shares with the dialog around it: whether the person reads at its end, the
/// last reply seen there, and how tall it is laid out.
@MainActor @Observable
final class PersonalAgentReplyTableState {
    var isFollowing = true
    var seenLast: String?
    var contentHeight: CGFloat = 0
    @ObservationIgnored weak var controller: PersonalAgentReplyTableController?

    /// Moves to the newest reply and reads at the end again.
    func showEnd() { controller?.showEnd() }
}

/// A row of the reply list: the earlier replies' row, a message, or the line saying there is none.
enum PersonalAgentReplyEntry: Hashable {
    case earlier
    case message(String)
    case empty

    var messageID: String? { if case let .message(id) = self { id } else { nil } }
}

/// The reply dialog's messages as a native list: a row for every message read, a view only for the
/// rows in view, each drawn in the hosting view its row reuses (`PersonalAgentReplyRowHosting`).
struct PersonalAgentReplyTable: NSViewRepresentable {
    struct Earlier {
        let signature: String
        let content: AnyView
    }

    let messages: [PersonalAgentMessage]
    let earlier: Earlier?
    let showsEmpty: Bool
    let empty: AnyView
    let rows: PersonalAgentReplyRows
    let state: PersonalAgentReplyTableState
    let readEarlierByItself: () -> Void

    func makeCoordinator() -> PersonalAgentReplyTableController { PersonalAgentReplyTableController(state: state) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self, environment: context.environment)
    }
}

/// The list's table, read by assistive apps through the rows it has views for: each row's message, as
/// drawn, rather than the table's row placeholders, which carry no content of their own here.
final class PersonalAgentReplyTableView: NSTableView {
    override func accessibilityChildren() -> [Any]? {
        var rows: [Any] = []
        enumerateAvailableRowViews { rowView, _ in rows.append(contentsOf: rowView.subviews) }
        return rows
    }
}

/// A row of the reply list, named by the message it shows, with the hosting view it draws in.
final class PersonalAgentReplyRowView: NSView {
    var messageID = ""
    var entry: PersonalAgentReplyEntry?
    let hosting = PersonalAgentReplyRowHosting()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(hosting.controller.view)
        // The message's own content is what assistive apps read in the row.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The message's content within the list's side margins.
    override func layout() {
        super.layout()
        let inset = PersonalAgentReplyTableController.sideInset
        hosting.controller.view.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: bounds.height)
    }
}

/// Keeps the list in step with the thread. Rows come and go as messages do (inserted, removed, moved by
/// identity, never reloaded whole); only rows in view are drawn, and a row's height is measured once it
/// is drawn, estimated before. Before anything changes the list, the message at the top of the view and
/// how far into it the view starts are noted, and the view returns there after, unless the person reads
/// at the end, which it then follows. A row being edited is the table's own in-use row, which it neither
/// removes nor hands to another message while editing goes on.
@MainActor
final class PersonalAgentReplyTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let cellID = NSUserInterfaceItemIdentifier("PersonalAgentReplyRow")
    static let sideInset: CGFloat = 14
    static let verticalInset: CGFloat = 8
    /// How near the top the earlier replies are read, as the provider's dialog has it.
    static let topDistance: CGFloat = 160
    /// The earlier replies' row, as the dialog draws it.
    static let earlierHeight: CGFloat = 28
    /// How much of a message read partway stays in view, at most, when it becomes shorter.
    static let keptInView: CGFloat = 48

    let state: PersonalAgentReplyTableState
    let scrollView = NSScrollView()
    let table = PersonalAgentReplyTableView()
    private var entries: [PersonalAgentReplyEntry] = []
    private var messages: [String: PersonalAgentMessage] = [:]
    private var index: [String: Int] = [:]
    private var ordered: [PersonalAgentMessage] = []
    private var source: PersonalAgentReplyTable?
    private var environment = EnvironmentValues()
    private var look: PersonalAgentReplyRowLook?
    private var conversationLook: ConversationTurnLook?
    /// Rows' heights as the table has them: what it was told for each row, which it keeps until it is
    /// told a row's height changed. A row not drawn yet keeps the estimate it was first given.
    private var known: [PersonalAgentReplyEntry: CGFloat] = [:]
    /// Rows' heights as drawn at `measuredWidth` and look, told to the table once this turn's changes are
    /// in; their sum and count give the estimate for rows not drawn yet.
    private var measured: [PersonalAgentReplyEntry: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var measuredTotal: CGFloat = 0
    /// Moving the view on its own, which the person did not do.
    private var adjusting = 0
    private var lastTop: CGFloat?
    /// The earlier replies' row, kept blank where the person sees it after there is nothing more to
    /// read, until they scroll it out of view: taking it away at once would move what they read.
    private var lingersEarlier = false
    private var pendingHeights: Set<PersonalAgentReplyEntry> = []
    private var flushScheduled = false
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

    init(state: PersonalAgentReplyTableState) {
        self.state = state
        super.init()
        state.controller = self
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: ConversationLayout.turnSpacing)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowSizeStyle = .custom
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L10n.string("Replies"))
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widthChanged() }
        }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    // MARK: - Updates

    func update(_ source: PersonalAgentReplyTable, environment: EnvironmentValues) {
        let first = self.source == nil
        self.source = source
        self.environment = environment
        let newLook = ConversationTurnLook(environment)
        let looksChanged = look != source.rows.look || conversationLook != newLook
        look = source.rows.look
        conversationLook = newLook
        var changed: [String] = []
        var nextMessages: [String: PersonalAgentMessage] = [:]
        var nextIndex: [String: Int] = [:]
        nextMessages.reserveCapacity(source.messages.count)
        nextIndex.reserveCapacity(source.messages.count)
        for (offset, message) in source.messages.enumerated() {
            if let old = messages[message.id], old != message { changed.append(message.id) }
            nextMessages[message.id] = message
            nextIndex[message.id] = offset
        }
        messages = nextMessages
        index = nextIndex
        ordered = source.messages
        if looksChanged { forgetMeasured() } else { for id in changed { setMeasured(.message(id), nil) } }
        // Only where the person reads up: at the end, the row goes without moving what they read.
        lingersEarlier = source.earlier == nil && entries.first == .earlier && !state.isFollowing
            && (lingersEarlier || earlierInView)
        let next = (source.earlier != nil || lingersEarlier ? [PersonalAgentReplyEntry.earlier] : [])
            + source.messages.map { .message($0.id) } + (source.showsEmpty ? [.empty] : [])
        if first {
            entries = next
            table.reloadData()
            settle()
            return
        }
        let anchor = state.isFollowing ? nil : captureAnchor()
        if next != entries { apply(next) }
        // Only the rows in view are drawn again, and only those whose content changed redraw.
        reconfigureVisible()
        if let anchor { restore(anchor) }
        settle()
    }

    /// Brings the rows to `next` by identity: rows gone are removed, rows still there are moved where
    /// their order changed, keeping their views, and new rows are inserted. Nothing is reloaded.
    private func apply(_ next: [PersonalAgentReplyEntry]) {
        let kept = Set(next)
        var working = entries
        let removed = IndexSet(working.indices.filter { !kept.contains(working[$0]) })
        let before = Set(entries)
        for offset in removed {
            setMeasured(working[offset], nil)
            known[working[offset]] = nil
            pendingHeights.remove(working[offset])
        }
        withoutAnimation {
            table.beginUpdates()
            if !removed.isEmpty {
                for offset in removed.reversed() { working.remove(at: offset) }
                entries = working
                table.removeRows(at: removed, withAnimation: [])
            }
            let order = next.filter { before.contains($0) }
            for (target, entry) in order.enumerated() where working[target] != entry {
                guard let from = working[target...].firstIndex(of: entry) else { continue }
                working.insert(working.remove(at: from), at: target)
                entries = working
                table.moveRow(at: from, to: target)
            }
            let inserted = IndexSet(next.indices.filter { !before.contains(next[$0]) })
            entries = next
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
        }
    }

    /// After a change: the end followed or the place kept, the heights reported, the top checked.
    private func settle() {
        if state.isFollowing {
            scrollToEnd()
            if let last = ordered.last?.id, state.seenLast != last { state.seenLast = last }
        }
        report()
        checkTop()
    }

    /// The rows that have views now, in view or about to be, drawn again where what they show changed
    /// and measured again.
    private func reconfigureVisible() {
        table.enumerateAvailableRowViews { rowView, row in
            guard row >= 0, row < entries.count, let cell = rowView.view(atColumn: 0) as? PersonalAgentReplyRowView else { return }
            configure(cell, entries[row])
            measure(cell, entries[row])
        }
    }

    private func configure(_ cell: PersonalAgentReplyRowView, _ entry: PersonalAgentReplyEntry) {
        guard let source else { return }
        cell.entry = entry
        cell.messageID = entry.messageID ?? ""
        cell.hosting.onResize = { [weak self, weak cell] in
            guard let self, let cell, let entry = cell.entry else { return }
            self.measure(cell, entry)
        }
        switch entry {
        case let .message(id):
            guard let message = messages[id] else { return }
            let startsRun = startsRun(id)
#if DEBUG
            ViewBodyCensus.note(.personalAgentReplyRow)
#endif
            cell.hosting.show(.message(source.rows.inputs(message, startsRun), source.rows.look), identity: id,
                              environment: environment) { source.rows.content(message, startsRun) }
        case .earlier:
            if let earlier = source.earlier {
                cell.hosting.show(.other("earlier|" + earlier.signature), identity: "earlier", environment: environment) {
                    earlier.content
                }
            } else {
                cell.hosting.show(.other("earlier|gone"), identity: "earlier", environment: environment) {
                    AnyView(Color.clear.frame(height: PersonalAgentReplyTableController.earlierHeight))
                }
            }
        case .empty:
            cell.hosting.show(.other("empty"), identity: "empty", environment: environment) { source.empty }
        }
    }

    private func startsRun(_ id: String) -> Bool {
        guard let offset = index[id], offset > 0 else { return true }
        return ordered[offset - 1].author != ordered[offset].author
    }

    // MARK: - Heights

    private var contentWidth: CGFloat { max(0, (table.tableColumns.first?.width ?? table.bounds.width) - 2 * Self.sideInset) }

    private var estimate: CGFloat { measured.isEmpty ? 60 : measuredTotal / CGFloat(measured.count) }

    /// Sets or forgets a row's height as drawn, keeping the sum the estimate is made of.
    private func setMeasured(_ entry: PersonalAgentReplyEntry, _ height: CGFloat?) {
        measuredTotal += (height ?? 0) - (measured[entry] ?? 0)
        measured[entry] = height
        if measured.isEmpty { measuredTotal = 0 }
    }

    /// Every height drawn is stale, at a new width or look; the table keeps what it was told until the
    /// rows are drawn again.
    private func forgetMeasured() {
        measured = [:]
        measuredTotal = 0
    }

    /// The height `cell` draws `entry` at, told to the table once this turn's changes are in.
    private func measure(_ cell: PersonalAgentReplyRowView, _ entry: PersonalAgentReplyEntry) {
        let width = contentWidth
        guard width > 0 else { return }
        if width != measuredWidth {
            measuredWidth = width
            forgetMeasured()
        }
        let height = max(1, cell.hosting.size(forWidth: width).height)
        setMeasured(entry, height)
        guard known[entry] != height else { return }
        pendingHeights.insert(entry)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushHeights() }
    }

    private func flushHeights() {
        flushScheduled = false
        let changes = pendingHeights.compactMap { entry -> (PersonalAgentReplyEntry, CGFloat, Int)? in
            guard let row = row(of: entry), let height = measured[entry], known[entry] != height else { return nil }
            return (entry, height, row)
        }
        pendingHeights = []
        guard !changes.isEmpty else { return }
        // The place is read while the table and its rows agree on the heights it has; the new heights
        // are told the moment they are given, with nothing reading the table in between.
        let anchor = state.isFollowing ? nil : captureAnchor()
        for (entry, height, _) in changes { known[entry] = height }
        withoutAnimation { table.noteHeightOfRows(withIndexesChanged: IndexSet(changes.map(\.2))) }
        if let anchor { restore(anchor) }
        settle()
    }

    private func report() {
        let height = (entries.isEmpty ? 0 : table.rect(ofRow: entries.count - 1).maxY) + 2 * Self.verticalInset
        if abs(state.contentHeight - height) > 0.5 { state.contentHeight = height }
    }

    // MARK: - Place

    /// A message the view starts at or above, how far into it, and how tall it was then, without the
    /// space after it.
    private struct Anchor {
        let entry: PersonalAgentReplyEntry
        let offset: CGFloat
        let height: CGFloat
    }

    /// The first message at or below the top of the view, and how far into it the view starts; a status
    /// row at the top counts the message under it, so it can go without moving that message.
    private func captureAnchor() -> Anchor? {
        let top = scrollView.contentView.bounds.minY
        var row = table.row(at: NSPoint(x: 1, y: max(0, top)))
        if row < 0 { row = entries.indices.first { table.rect(ofRow: $0).maxY > top } ?? -1 }
        guard row >= 0 else { return nil }
        let at = entries[row...].firstIndex { $0.messageID != nil } ?? row
        let rect = table.rect(ofRow: at)
        return Anchor(entry: entries[at], offset: top - rect.minY, height: rect.height - table.intercellSpacing.height)
    }

    /// Returns to the message noted, as far into it as the view started. A message that became shorter
    /// keeps as much of itself in view as before, up to `keptInView`; a status row above it, which a
    /// negative offset counts back to, stays.
    private func restore(_ anchor: Anchor) {
        guard let row = row(of: anchor.entry) else { return }
        let rect = table.rect(ofRow: row)
        var offset = anchor.offset
        if offset > 0 {
            let height = rect.height - table.intercellSpacing.height
            let shown = min(height, anchor.height - offset, Self.keptInView)
            offset = min(offset, max(0, height - shown))
        }
        scroll(to: rect.minY + offset)
    }

    private func row(of entry: PersonalAgentReplyEntry) -> Int? {
        if let id = entry.messageID, let offset = index[id] {
            let row = offset + (entries.first == .earlier ? 1 : 0)
            return row < entries.count && entries[row] == entry ? row : entries.firstIndex(of: entry)
        }
        return entries.firstIndex(of: entry)
    }

    private func scroll(to top: CGFloat) {
        let clip = scrollView.contentView
        let highest = -Self.verticalInset
        let lowest = max(highest, table.frame.height + Self.verticalInset - clip.bounds.height)
        let target = min(max(highest, top), lowest)
        guard abs(clip.bounds.minY - target) > 0.25 else { return }
        adjusting += 1
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
        adjusting -= 1
    }

    private func scrollToEnd() {
        scroll(to: .greatestFiniteMagnitude)
    }

    func showEnd() {
        state.isFollowing = true
        state.seenLast = ordered.last?.id
        scrollToEnd()
        checkTop()
    }

    private var earlierInView: Bool {
        entries.first == .earlier && table.rect(ofRow: 0).maxY > scrollView.contentView.bounds.minY
    }

    /// The person moved the view: reading at the end, or away from it. The view moving on its own, as
    /// the list keeps a place or follows the end, is neither.
    private func scrolled() {
        let clip = scrollView.contentView
        let top = clip.bounds.minY
        defer { lastTop = top }
        guard adjusting == 0 else { return }
        // The blank row the person has scrolled past goes, keeping what they read where it is.
        if lingersEarlier, !earlierInView {
            lingersEarlier = false
            let anchor = state.isFollowing ? nil : captureAnchor()
            apply(Array(entries.dropFirst()))
            if let anchor { restore(anchor) }
            report()
        }
        let atEnd = table.frame.height + Self.verticalInset - clip.bounds.maxY <= 96
        if atEnd {
            if !state.isFollowing { state.isFollowing = true }
            if let last = ordered.last?.id, state.seenLast != last { state.seenLast = last }
        } else if let lastTop, lastTop != top, state.isFollowing {
            state.isFollowing = false
        }
        checkTop()
    }

    /// With the top in view, or a thread that does not fill the view, the earlier replies are read.
    private func checkTop() {
        let clip = scrollView.contentView
        guard !entries.isEmpty, clip.bounds.height > 0 else { return }
        if clip.bounds.minY + Self.verticalInset <= Self.topDistance
            || table.frame.height + 2 * Self.verticalInset <= clip.bounds.height + 1 {
            source?.readEarlierByItself()
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 1 }
        let entry = entries[row]
        if let height = known[entry] { return height }
        let height = max(1, measured[entry] ?? estimate)
        known[entry] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let cell: PersonalAgentReplyRowView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? PersonalAgentReplyRowView {
            cell = reused
        } else {
            cell = PersonalAgentReplyRowView()
            cell.identifier = Self.cellID
        }
        configure(cell, entry)
        measure(cell, entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableViewColumnDidResize(_ notification: Notification) { widthChanged() }

    /// A new width: every height measured is stale, and the rows with views are measured again.
    private func widthChanged() {
        guard contentWidth > 0, contentWidth != measuredWidth else { return }
        measuredWidth = contentWidth
        forgetMeasured()
        reconfigureVisible()
    }
}
