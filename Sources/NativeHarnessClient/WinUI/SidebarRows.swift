import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The sidebar's measures and colors, as the Mac's (`SidebarMetrics`, `SidebarTaskStatusView`).
@MainActor
enum SidebarStyle {
    static let rowHeight: Double = 30
    static let homeRowHeight: Double = 32
    static let rowCornerRadius: Double = 10
    /// The space each row keeps from the sidebar's edges.
    static let rowInset: Double = 4
    /// The column a row's mark sits in, where every row's words start after it.
    static let gutterWidth: Double = 32
    /// How far a task started from another sits in from it, and the guide joining them (the Claude app's
    /// `.df-family:after`): 10 across, its corner rounded at 6.
    static let familyIndent: Double = 20
    static let familyGuideLength: Double = 10
    static let familyGuideRadius: Double = 6
    /// The guide's line, stronger than a separator, as the Mac's `SidebarFamilyGuide.color`.
    static let familyGuide = ThemeColor(light: .ink(0.22), dark: .paper(0.22))
    /// The "Show more" and family summary lines.
    static let secondaryLineHeight: Double = 28
    static let rowTrailingPadding: Double = 8
    static let titleFontSize: Double = 13
    /// Section and project labels' text starts here, from the sidebar's edge.
    static let labelLeading: Double = 13
    static let labelFontSize: Double = 12
    static let statusDotSize: Double = 6

    /// The marks' colors: green for an approval, orange for a question and a limit, red for a failure, as the Mac's
    /// system colors draw them.
    static let green = ThemeColor(light: .rgb(0.20, 0.78, 0.35), dark: .rgb(0.19, 0.82, 0.35))
    static let orange = ThemeColor(light: .rgb(1.00, 0.58, 0.00), dark: .rgb(1.00, 0.62, 0.04))
    static let red = ThemeColor(light: .rgb(1.00, 0.23, 0.19), dark: .rgb(1.00, 0.27, 0.23))
    static let clear = SolidColorBrush(UWP.Color(a: 0, r: 0, g: 0, b: 0))

    /// A list's rows filled as the Mac's are under the pointer and when chosen, gray rather than Windows' accent, with
    /// no selection bar: Windows' list draws its rows from these resources (lightweight styling). `rest` fills a
    /// row that is neither, as Home's row is filled.
    static func styleRows(of list: ListView, rest: ThemeColor? = nil) {
        let resources = list.resources
        func set(_ key: String, _ value: Any) { _ = resources?.insert(key, value) }
        set("ListViewItemBackground", rest?.brush ?? clear)
        set("ListViewItemBackgroundPointerOver", (rest == nil ? WindowsTheme.hoverFill : WindowsTheme.selectedFill).brush)
        set("ListViewItemBackgroundPressed", WindowsTheme.selectedFill.brush)
        set("ListViewItemBackgroundSelected", WindowsTheme.selectedFill.brush)
        set("ListViewItemBackgroundSelectedPointerOver", WindowsTheme.selectedFill.brush)
        set("ListViewItemBackgroundSelectedPressed", WindowsTheme.selectedFill.brush)
        set("ListViewItemSelectionIndicatorVisualEnabled", false)
        set("ListViewItemSelectionIndicatorBrush", clear)
        set("ListViewItemSelectionIndicatorPointerOverBrush", clear)
        set("ListViewItemSelectionIndicatorPressedBrush", clear)
    }

    /// A button drawn as the sidebar's words are, with no frame: a fill under the pointer only.
    static func stylePlain(_ button: Button) {
        let resources = button.resources
        func set(_ key: String, _ value: Any) { _ = resources?.insert(key, value) }
        set("ButtonBackground", clear)
        set("ButtonBackgroundPointerOver", WindowsTheme.hoverFill.brush)
        set("ButtonBackgroundPressed", WindowsTheme.selectedFill.brush)
        set("ButtonBackgroundDisabled", clear)
        set("ButtonBorderBrush", clear)
        set("ButtonBorderBrushPointerOver", clear)
        set("ButtonBorderBrushPressed", clear)
        set("ButtonBorderBrushDisabled", clear)
        button.background = clear
        button.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.cornerRadius = CornerRadius(topLeft: rowCornerRadius, topRight: rowCornerRadius,
                                           bottomRight: rowCornerRadius, bottomLeft: rowCornerRadius)
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
    }

    static func label(_ words: String, size: Double = labelFontSize, color: ThemeColor = WindowsTheme.secondaryText,
                      semibold: Bool = false) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.fontSize = size
        block.foreground = color.brush
        block.textWrapping = .noWrap
        block.textTrimming = .characterEllipsis
        block.maxLines = 1
        block.verticalAlignment = .center
        if semibold { block.fontWeight = UWP.FontWeight(weight: 600) }
        return block
    }

    /// A Segoe Fluent Icons glyph, as Windows' own apps draw their symbols.
    static func glyph(_ code: String, size: Double = 12, color: ThemeColor = WindowsTheme.text) -> FontIcon {
        let icon = FontIcon()
        icon.glyph = code
        icon.fontSize = size
        icon.foreground = color.brush
        return icon
    }

    static func columns(_ grid: Grid, _ widths: [GridLength]) {
        for width in widths {
            let column = ColumnDefinition()
            column.width = width
            grid.columnDefinitions.append(column)
        }
    }

    static let auto = GridLength(value: 0, gridUnitType: .auto)
    static let star = GridLength(value: 1, gridUnitType: .star)
    static func pixels(_ value: Double) -> GridLength { GridLength(value: value, gridUnitType: .pixel) }
}

/// One of the sidebar's lists: Windows' list control, its rows filled as the Mac's are, scrolling with the sidebar
/// rather than on its own. A list is rebuilt only when the rows it holds or their order change; a row whose words or
/// state change is redrawn in place (`SidebarTaskRow`).
@MainActor
final class SidebarList {
    let view = ListView()
    /// The rows' keys, in the list's order.
    private(set) var keys: [String] = []
    /// Called with the key of the row the person chose, by pointer, keyboard or UI Automation.
    var onPick: (String) -> Void = { _ in }
    /// Set while the list's rows or choice change in code, when a change of choice is not the person's.
    var isQuiet = false

    init(rest: ThemeColor? = nil) {
        view.selectionMode = .single
        view.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        // The sidebar scrolls as one; a list scrolling on its own would keep the wheel from it.
        try? ScrollViewer.setVerticalScrollMode(view, .disabled)
        try? ScrollViewer.setVerticalScrollBarVisibility(view, .disabled)
        try? ScrollViewer.setHorizontalScrollMode(view, .disabled)
        try? ScrollViewer.setHorizontalScrollBarVisibility(view, .disabled)
        // Rows redrawn as tasks change come in place, not sliding in.
        view.itemContainerTransitions?.clear()
        SidebarStyle.styleRows(of: view, rest: rest)
        view.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isQuiet else { return }
            let index = Int(self.view.selectedIndex)
            guard self.keys.indices.contains(index) else { return }
            self.onPick(self.keys[index])
        }
    }

    /// Whether `keys` differ from the rows the list holds.
    func differs(_ keys: [String]) -> Bool { keys != self.keys }

    /// Takes every row out, so each can go to another list.
    func empty() {
        isQuiet = true
        view.items.clear()
        keys = []
        isQuiet = false
    }

    /// Puts `rows` in, in order, after `empty()`.
    func fill(_ rows: [(key: String, item: ListViewItem)]) {
        isQuiet = true
        for row in rows { view.items.append(row.item) }
        keys = rows.map(\.key)
        isQuiet = false
    }

    /// Shows the row with `key` chosen, or none.
    func choose(_ key: String?) {
        let index = key.flatMap { keys.firstIndex(of: $0) } ?? -1
        guard Int(view.selectedIndex) != index else { return }
        isQuiet = true
        view.selectedIndex = Int32(index)
        isQuiet = false
    }

    /// A row of the list's own, such as Home or Settings: a symbol in the rows' gutter and its words where task titles
    /// start, named for UI Automation as it reads.
    static func actionRow(glyph: String, title: String, height: Double = SidebarStyle.rowHeight,
                          weight: UInt16 = 400) -> ListViewItem {
        let grid = Grid()
        grid.height = height
        SidebarStyle.columns(grid, [SidebarStyle.pixels(SidebarStyle.gutterWidth), SidebarStyle.star])
        let mark = SidebarStyle.glyph(glyph, size: 14)
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .center
        grid.children.append(mark)
        let words = SidebarStyle.label(title, size: SidebarStyle.titleFontSize, color: WindowsTheme.text)
        words.fontWeight = UWP.FontWeight(weight: weight)
        try? Grid.setColumn(words, 1)
        grid.children.append(words)
        let item = ListViewItem()
        SidebarList.shape(item)
        item.content = grid
        try? AutomationProperties.setName(item, title)
        return item
    }

    /// A row's place and shape, as the Mac's rows sit: inset from the sidebar's edges, rounded, one point apart.
    static func shape(_ item: ListViewItem) {
        item.minHeight = 0
        item.padding = Thickness(left: 0, top: 0, right: SidebarStyle.rowTrailingPadding, bottom: 0)
        item.margin = Thickness(left: SidebarStyle.rowInset, top: 0, right: SidebarStyle.rowInset, bottom: 1)
        item.horizontalContentAlignment = .stretch
        item.cornerRadius = CornerRadius(topLeft: SidebarStyle.rowCornerRadius, topRight: SidebarStyle.rowCornerRadius,
                                         bottomRight: SidebarStyle.rowCornerRadius,
                                         bottomLeft: SidebarStyle.rowCornerRadius)
    }
}

/// A task's row, as the Mac's: its harness's mark, its title on one line (semibold while its result is unread), a
/// level further in for each task it was started through with the family's guide leading to it, and its state at the
/// end (`SidebarTaskIndicatorProjection`). Its menu is the Mac's row menu (`TaskActions.rowMenu`).
@MainActor
final class SidebarTaskRow {
    struct State: Equatable {
        var title: String
        var harness: HarnessKind
        var isUnread: Bool
        var status: SidebarTaskStatus?
        /// Where it sits in the family it is nested in; nil at the top level.
        var place: SidebarFamilyPlace?
    }

    let item = ListViewItem()
    private let grid = Grid()
    private let guides = Grid()
    private let mark = Border()
    private let title = TextBlock()
    private let end = Grid()
    private var drawn: State?

    init(id: UUID, actions: TaskActions, family: @escaping @MainActor () -> TaskActions.Family?) {
        SidebarList.shape(item)
        grid.height = SidebarStyle.rowHeight
        SidebarStyle.columns(grid, [SidebarStyle.auto, SidebarStyle.star, SidebarStyle.auto])
        guides.isHitTestVisible = false
        try? Grid.setColumnSpan(guides, 3)
        grid.children.append(guides)
        mark.width = SidebarStyle.gutterWidth
        grid.children.append(mark)
        title.fontSize = SidebarStyle.titleFontSize
        title.foreground = WindowsTheme.text.brush
        title.textWrapping = .noWrap
        title.textTrimming = .characterEllipsis
        title.maxLines = 1
        title.verticalAlignment = .center
        try? Grid.setColumn(title, 1)
        grid.children.append(title)
        end.width = 14
        end.height = 14
        end.margin = Thickness(left: 3, top: 0, right: 0, bottom: 0)
        end.verticalAlignment = .center
        try? Grid.setColumn(end, 2)
        grid.children.append(end)
        item.content = grid
        item.contextFlyout = actions.rowMenu(for: id, family: family)
    }

    /// Draws `state`, changing only what differs from what the row shows.
    func show(_ state: State) {
        guard state != drawn else { return }
        let before = drawn
        drawn = state
        if before?.harness != state.harness {
            mark.child = HarnessIcon.element(for: state.harness)
        }
        if before?.place != state.place {
            let depth = Double(state.place?.depth ?? 0)
            mark.margin = Thickness(left: depth * SidebarStyle.familyIndent, top: 0, right: 0, bottom: 0)
            SidebarFamilyGuide.draw(state.place, in: guides, height: SidebarStyle.rowHeight)
        }
        if before?.title != state.title {
            title.text = state.title
            try? AutomationProperties.setName(item, state.title)
        }
        if before?.isUnread != state.isUnread {
            title.fontWeight = UWP.FontWeight(weight: state.isUnread ? 600 : 400)
        }
        if before?.status != state.status {
            end.children.clear()
            if let status = state.status { end.children.append(SidebarStatusMark.view(status)) }
        }
        let help = ([state.title] + (state.status.map { [$0.help] } ?? [])).joined(separator: "\n")
        try? ToolTipService.setToolTip(item, help)
    }
}

/// A task's state at a row's end, as the Mac's `SidebarTaskStatusView` draws it: a small dot (green for an approval,
/// orange for a question, gray while a turn runs, the accent for an unread result), and in place of a dot a warning
/// for a failed turn, a gauge for a plan limit, a globe while the browser waits and arrows while reconnecting.
@MainActor
enum SidebarStatusMark {
    static func view(_ status: SidebarTaskStatus) -> FrameworkElement {
        switch status {
        case .awaitingApproval: dot(SidebarStyle.green)
        case .needsInput: dot(SidebarStyle.orange)
        case .waitingInBrowser: symbol("\u{E774}", SidebarStyle.orange)
        case .failed: symbol(ConversationStyle.Glyph.warning, SidebarStyle.red)
        case .usageLimit: symbol("\u{EC4A}", SidebarStyle.orange)
        case .running: SidebarBlink.shared.blinking(dot(WindowsTheme.secondaryText))
        case .reconnecting: symbol("\u{E895}", WindowsTheme.secondaryText)
        case .unread: dot(WindowsTheme.accent)
        }
    }

    private static func dot(_ color: ThemeColor) -> FrameworkElement {
        let dot = Ellipse()
        dot.width = SidebarStyle.statusDotSize
        dot.height = SidebarStyle.statusDotSize
        dot.fill = color.brush
        dot.horizontalAlignment = .center
        dot.verticalAlignment = .center
        return dot
    }

    private static func symbol(_ glyph: String, _ color: ThemeColor) -> FrameworkElement {
        let icon = SidebarStyle.glyph(glyph, size: 10, color: color)
        icon.horizontalAlignment = .center
        icon.verticalAlignment = .center
        return icon
    }
}

/// The lines joining a nested task to its family, as the Mac's `SidebarFamilyGuide` draws them (the Claude app's
/// `.df-family:after`): at the task's level, down from the row above, then across toward the task's mark round a
/// corner, carried on down when more of that level follows; at each level further out whose line runs on to a later
/// row, straight through (`SidebarFamilyPlace.continuingLevels`). Each line is a level's, under the middle of the mark
/// of the row a level out, and starts a point above the row, across the gap between rows.
@MainActor
enum SidebarFamilyGuide {
    static func draw(_ place: SidebarFamilyPlace?, in guides: Grid, height: Double) {
        guides.children.clear()
        guard let place else { return }
        let middle = (height / 2).rounded(.down)
        for level in place.continuingLevels.sorted() where level < place.depth {
            guides.children.append(line(x: x(level), top: -1, height: nil))
        }
        // Down to the corner and across: a box whose left and bottom edges are the line, its corner rounded.
        let elbow = Border()
        elbow.horizontalAlignment = .left
        elbow.verticalAlignment = .top
        elbow.width = SidebarStyle.familyGuideLength + 1
        elbow.height = middle + 2
        elbow.margin = Thickness(left: x(place.depth), top: -1, right: 0, bottom: 0)
        elbow.borderBrush = SidebarStyle.familyGuide.brush
        elbow.borderThickness = Thickness(left: 1, top: 0, right: 0, bottom: 1)
        elbow.cornerRadius = CornerRadius(topLeft: 0, topRight: 0, bottomRight: 0,
                                          bottomLeft: SidebarStyle.familyGuideRadius)
        guides.children.append(elbow)
        if place.continuingLevels.contains(place.depth) {
            guides.children.append(line(x: x(place.depth), top: middle - SidebarStyle.familyGuideRadius, height: nil))
        }
    }

    /// Where a level's line runs down, from the row's start: under the middle of the mark of the row a level out
    /// (level 1 under the family's top task), as the Mac's `SidebarRowLeading.guideX`.
    private static func x(_ level: Int) -> Double {
        Double(level - 1) * SidebarStyle.familyIndent + SidebarStyle.gutterWidth / 2
    }

    private static func line(x: Double, top: Double, height: Double?) -> Rectangle {
        let line = Rectangle()
        line.width = 1
        line.horizontalAlignment = .left
        line.verticalAlignment = .stretch
        line.margin = Thickness(left: x, top: top, right: 0, bottom: 0)
        line.fill = SidebarStyle.familyGuide.brush
        return line
    }
}

/// The line under a collapsed family, as the Mac's `SidebarFamilySummaryLine` (the Claude app's `df-family-stub`):
/// how many nested tasks it hides, "more" when some stay listed, and of those how many failed, have something new
/// (after the unread dot) and are working, with the warning at its end when one failed. Choosing it shows them again.
@MainActor
final class SidebarFamilySummaryRow {
    struct State: Equatable {
        var counts: SidebarFamilySummary
        /// Some nested tasks are still listed above the line.
        var showsMore: Bool
    }

    let item = ListViewItem()
    private let grid = Grid()
    private let words = TextBlock()
    private let end = Grid()
    private var drawn: State?

    init() {
        SidebarList.shape(item)
        grid.height = SidebarStyle.secondaryLineHeight
        SidebarStyle.columns(grid, [SidebarStyle.star, SidebarStyle.auto])
        let guides = Grid()
        guides.isHitTestVisible = false
        try? Grid.setColumnSpan(guides, 2)
        SidebarFamilyGuide.draw(SidebarFamilyPlace(depth: 1), in: guides, height: SidebarStyle.secondaryLineHeight)
        grid.children.append(guides)
        words.fontSize = SidebarStyle.labelFontSize
        words.foreground = WindowsTheme.secondaryText.brush
        words.textWrapping = .noWrap
        words.textTrimming = .characterEllipsis
        words.maxLines = 1
        words.verticalAlignment = .center
        // Its words start where a nested task's mark does.
        words.margin = Thickness(left: SidebarStyle.familyIndent + (SidebarStyle.gutterWidth - 16) / 2, top: 0,
                                 right: 4, bottom: 0)
        grid.children.append(words)
        end.width = 14
        end.height = 14
        end.verticalAlignment = .center
        try? Grid.setColumn(end, 1)
        grid.children.append(end)
        item.content = grid
    }

    /// Draws `state` when it differs from what the line shows.
    func show(_ state: State) {
        guard state != drawn else { return }
        drawn = state
        let counts = state.counts
        let details = SidebarFamilySummary.detailTexts(counts)
        words.inlines.clear()
        func add(_ text: String, color: ThemeColor? = nil, size: Double? = nil) {
            let run = Run()
            run.text = text
            if let color { run.foreground = color.brush }
            if let size { run.fontSize = size }
            words.inlines.append(run)
        }
        add(SidebarFamilySummary.sessionsText(counts.sessions, more: state.showsMore))
        if let failed = details.failed { add(" · " + failed) }
        if let new = details.new {
            add(" · ")
            add("\u{25CF}", color: WindowsTheme.accent, size: 7)
            add(" " + new)
        }
        if let working = details.working { add(" · " + working) }
        end.children.clear()
        if counts.failed > 0 { end.children.append(SidebarStatusMark.view(.failed(message: nil))) }
        try? AutomationProperties.setName(item, SidebarFamilySummary.accessibilityLabel(counts, more: state.showsMore))
        try? ToolTipService.setToolTip(item, SidebarFamilySummary.help(counts, more: state.showsMore))
    }
}

/// The working dot's fade, as the Mac's `BlinkingDot`: to 30% and back every 1.2 s. One fade serves every dot: it
/// runs on a property of its own on Windows' compositor, and each dot's opacity is bound to that property, so every
/// working dot fades together, off the window's thread, and a list of working tasks costs the window nothing per
/// frame. With Windows' animation effects off (Settings › Accessibility › Visual effects) the dots hold still, as the
/// Mac's do with Reduce Motion; the setting is read again when the window comes to the front.
@MainActor
final class SidebarBlink {
    static let shared = SidebarBlink()

    private let settings = UWP.UISettings()
    private var compositor: WinAppSDK.Compositor?
    private var fade: WinAppSDK.CompositionPropertySet?
    private var binding: WinAppSDK.ExpressionAnimation?
    private var isMoving = false

    /// `dot`, its opacity following the shared fade.
    func blinking(_ dot: FrameworkElement) -> FrameworkElement {
        if let visual = try? ElementCompositionPreview.getElementVisual(dot), let binding = binding(visual.compositor) {
            try? visual.startAnimation("Opacity", binding)
        }
        return dot
    }

    /// Starts or stops the fade as Windows' animation effects are set now.
    func refresh() {
        guard let compositor, let fade else { return }
        let moves = settings.animationsEnabled
        guard moves != isMoving else { return }
        isMoving = moves
        QAEventLog.shared.write(moves ? "working dots fade" : "working dots hold still")
        if moves {
            guard let fading = try? compositor.createScalarKeyFrameAnimation() else { return }
            try? fading.insertKeyFrame(0, 1)
            try? fading.insertKeyFrame(0.5, 0.3)
            try? fading.insertKeyFrame(1, 1)
            fading.duration = WindowsFoundation.TimeSpan(duration: 12_000_000)
            fading.iterationBehavior = .forever
            try? fade.startAnimation("Opacity", fading)
        } else {
            try? fade.stopAnimation("Opacity")
            try? fade.insertScalar("Opacity", 1)
        }
    }

    /// The expression that reads the shared fade, made with the first dot's compositor, the window's.
    private func binding(_ compositor: WinAppSDK.Compositor?) -> WinAppSDK.ExpressionAnimation? {
        if let binding { return binding }
        guard let compositor, let fade = try? compositor.createPropertySet(),
              let binding = try? compositor.createExpressionAnimation("fade.Opacity") else { return nil }
        try? fade.insertScalar("Opacity", 1)
        try? binding.setReferenceParameter("fade", fade)
        self.compositor = compositor
        self.fade = fade
        self.binding = binding
        refresh()
        return binding
    }
}
