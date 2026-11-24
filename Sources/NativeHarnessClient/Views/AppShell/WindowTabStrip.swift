import SwiftUI

/// The window's own tab bar, as a browser's: a row of its own at the window's top once the window has two
/// tabs or more (Safari's default), in the sidebar's tone, over the header of the item the tab shows. The
/// shown tab stands on the canvas and runs into the header below it without a line, as a browser's shown
/// tab runs into its page; with the sidebar hidden the bar starts with the title bar's sidebar part, which
/// keeps the window's buttons on the bar's row.
struct WindowTabBar<SelectedTitle: View>: View {
    let tabs: TitleBarTabs
    /// The title bar's part for the window's buttons and the sidebar button (`TitleBarSidebarPart`), while
    /// the sidebar is hidden.
    var windowLead: AnyView? = nil
    @ViewBuilder let selectedTitle: () -> SelectedTitle

    var body: some View {
        HStack(spacing: 0) {
            if let windowLead { windowLead }
            HStack(spacing: 0) {
                WindowTabStrip(tabs: tabs.tabs, selection: tabs.selection, onSelect: tabs.onSelect,
                               onClose: tabs.onClose, onCloseOthers: tabs.onCloseOthers, onNewTab: tabs.onNewTab,
                               onOpenTask: tabs.onOpenTask, selectedTitle: selectedTitle)
                    .layoutPriority(1)
                WindowDragRegion().frame(minWidth: 24, maxWidth: .infinity)
            }
            .padding(.trailing, ParitySpace.s8)
        }
        .frame(height: ParityTheme.windowTabBarHeight)
        // The bar's edge runs under the tabs, and the shown tab covers it where it joins the header below.
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                ParityTheme.sidebar
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
            }
        }
        .accessibilitySortPriority(ParityAccessibility.titleBar)
        .focusSection()
    }
}

/// The window's task tabs, as a browser's tab bar (`WindowTabBar`). Each tab has the item's harness mark or
/// split mark, its title, and the state its sidebar row shows; the tab under the pointer and the active tab
/// show the close button instead. The active tab holds the shown item's title: a split view's opens its
/// actions, as a split view has no header of its own. "+" opens a new tab (⌘T).
///
/// A tab drags along the bar to another place, and a task's tab drags onto a pane's side to join a split
/// view (`WindowDragState`); the active tab drags by its mark and the room around its title. A sidebar
/// task dropped on the bar opens in a new tab where it was dropped, as a link dropped on Safari's tab bar.
struct WindowTabStrip<SelectedTitle: View>: View {
    let tabs: [WindowTab]
    let selection: WindowItem
    let onSelect: (WindowItem) -> Void
    let onClose: (WindowItem) -> Void
    let onCloseOthers: (WindowItem) -> Void
    let onNewTab: () -> Void
    /// A sidebar task dropped before a tab, or after the last (nil).
    var onOpenTask: (UUID, WindowItem?) -> Void = { _, _ in }
    @ViewBuilder let selectedTitle: () -> SelectedTitle

    @Environment(\.windowDrag) private var drag
    @State private var tabFrames: [WindowItem: CGRect] = [:]
    @State private var stripFrame: CGRect = .zero
    /// Where a sidebar task dragged over the bar would open.
    @State private var systemDropIndex: Int?
    /// This bar's registration, which a bar that replaced it keeps.
    @State private var token = UUID()

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                let widths = WindowTabMetrics.widths(count: tabs.count, available: proxy.size.width)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: WindowTabMetrics.spacing) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            let isSelected = tab.id == selection
                            let width = isSelected ? widths.shown : widths.other
                            WindowTabButton(
                                tab: tab,
                                isSelected: isSelected,
                                canClose: tabs.count > 1,
                                showsTitle: isSelected || width >= WindowTabMetrics.titledWidth,
                                // A hairline parts two tabs side by side; the shown tab's own edge parts it from its neighbours.
                                showsDivider: index > 0 && !isSelected && tabs[index - 1].id != selection,
                                onSelect: { onSelect(tab.id) },
                                onClose: { onClose(tab.id) },
                                onCloseOthers: { onCloseOthers(tab.id) },
                                selectedTitle: selectedTitle
                            )
                            .frame(width: width)
                            .offset(x: slide(index, width: (tabFrames[draggedItem ?? tab.id]?.width ?? width)
                                                + WindowTabMetrics.spacing))
                            // The shown tab's feet reach over its neighbours.
                            .zIndex(draggedIndex == index ? 2 : (isSelected ? 1 : 0))
                            // Read outside the offset: where the tab is laid out, not where it slid.
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                if tabFrames[tab.id] != frame { tabFrames[tab.id] = frame }
                            }
                            .overlay(alignment: .leading) {
                                if insertionIndex == index { TabInsertionMark().offset(x: -WindowTabMetrics.spacing - 1) }
                            }
                            .overlay(alignment: .trailing) {
                                if index == tabs.count - 1, insertionIndex == tabs.count {
                                    TabInsertionMark().offset(x: WindowTabMetrics.spacing + 1)
                                }
                            }
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, WindowTabMetrics.inset)
                    .frame(height: proxy.size.height, alignment: .bottom)
                    .animation(.easeOut(duration: 0.15), value: slideGap)
                }
            }
            .frame(maxWidth: WindowTabMetrics.idealWidth(count: tabs.count))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if stripFrame != frame { stripFrame = frame }
            }
            .onDrop(of: [.yardletTaskReference], delegate: TaskDropOnStrip(
                strip: { stripFrame }, tabs: { orderedFrames }, index: $systemDropIndex,
                onDrop: { id, index in onOpenTask(id, tabs.indices.contains(index) ? tabs[index].id : nil) }))
            ParityHeaderButton(systemName: "plus", help: L10n.string("New Tab"), shortcut: MacShortcut.newTab.binding,
                               action: onNewTab)
                // Level with the tabs, which stand on the bar's bottom edge.
                .padding(.top, WindowTabMetrics.barHeight - WindowTabMetrics.tabHeight)
        }
        // The first frames count too: a title bar drawn anew for another item registers its bar at once.
        .onChange(of: stripFrame, initial: true) { register() }
        .onChange(of: tabFrames, initial: true) { register() }
        .onChange(of: tabs.map(\.id)) { register() }
        .onDisappear { drag?.removeWindowTabs(token: token) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Tabs"))
    }

    private var orderedFrames: [CGRect] { tabs.compactMap { tabFrames[$0.id] } }

    private func register() {
        let frames = orderedFrames
        guard frames.count == tabs.count else { return }
        drag?.setWindowTabs(WindowDropGeometry.Strip(frame: stripFrame, tabs: frames, ids: tabs.map { AnyHashable($0.id) }),
                            token: token)
    }

    private var draggedItem: WindowItem? {
        guard case let .windowTab(item)? = drag?.subject else { return nil }
        return item
    }

    /// The tab of this bar being dragged, if one is.
    private var draggedIndex: Int? {
        guard case let .windowTab(item)? = drag?.subject else { return nil }
        return tabs.firstIndex { $0.id == item }
    }

    /// The gap a tab of this bar dragged along it would take.
    private var slideGap: Int? {
        guard draggedIndex != nil, case let .windowTabs(index)? = drag?.target else { return nil }
        return index
    }

    private func slide(_ index: Int, width: CGFloat) -> CGFloat {
        drag?.slide(index: index, dragged: draggedIndex, gap: slideGap, width: width, tabs: orderedFrames) ?? 0
    }

    /// Where something from elsewhere dragged over the bar would open: a pane's task, another task's
    /// conversation from a side panel, a sidebar task. The bar's own tabs make room instead.
    private var insertionIndex: Int? {
        if let systemDropIndex { return systemDropIndex }
        guard draggedIndex == nil, case let .windowTabs(index)? = drag?.target else { return nil }
        return index
    }

}

/// The tab bar's sizes.
enum WindowTabMetrics {
    static let tabMaxWidth: CGFloat = 240
    static let tabMinWidth: CGFloat = 120
    static let spacing: CGFloat = 0
    /// The bar's padding on each side, which keeps the shown tab's feet in the bar.
    static let inset: CGFloat = 10
    static let barHeight: CGFloat = ParityTheme.windowTabBarHeight
    /// A tab stands on the bar's bottom edge, the room above it the bar's.
    static let tabHeight: CGFloat = 30
    /// The shown tab's top corners, and the curves where its sides meet the bar's edge.
    static let cornerRadius: CGFloat = 8
    static let footRadius: CGFloat = 6

    /// The shown tab's width while the others can still give way; it holds the shown item's title.
    static let shownMinWidth: CGFloat = 170
    /// The narrowest the shown tab gets once the others are down to their marks; past that the bar scrolls.
    static let shownFloor: CGFloat = 96
    /// New Tab beside the bar.
    static let newTabWidth: CGFloat = 34
    /// The narrowest another tab gets: its mark alone.
    static let markWidth: CGFloat = 36
    /// Narrower than this, another tab shows its mark without its title.
    static let titledWidth: CGFloat = 90

    /// Tabs share the bar equally up to the maximum. Where that leaves a tab narrower than the minimum,
    /// the shown tab keeps a width its title can be read in and the others shrink, to their mark at the
    /// least, as Safari's compact tabs do; past that the bar scrolls.
    static func widths(count: Int, available: CGFloat) -> (shown: CGFloat, other: CGFloat) {
        guard count > 0 else { return (tabMaxWidth, tabMaxWidth) }
        let room = available - inset * 2 - CGFloat(count - 1) * spacing
        let even = room / CGFloat(count)
        if even >= tabMinWidth || count == 1 { return (min(tabMaxWidth, max(even, tabMinWidth)), min(tabMaxWidth, even)) }
        let others = CGFloat(count - 1)
        let other = max(markWidth, min(tabMinWidth, (room - shownMinWidth) / others))
        return (min(tabMaxWidth, max(shownFloor, room - others * other)), other)
    }

    /// The bar's width with every tab at its widest; what is left of the title bar moves the window.
    static func idealWidth(count: Int) -> CGFloat {
        CGFloat(count) * tabMaxWidth + CGFloat(max(0, count - 1)) * spacing + inset * 2
    }
}

private struct WindowTabButton<SelectedTitle: View>: View {
    let tab: WindowTab
    let isSelected: Bool
    let canClose: Bool
    /// A tab squeezed to its mark shows its title in its help.
    var showsTitle = true
    /// The hairline at its leading edge, between two tabs that are not shown.
    var showsDivider = false
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    @ViewBuilder let selectedTitle: () -> SelectedTitle
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var showsClose: Bool { canClose && (isHovering || isSelected) && showsTitle }

    var body: some View {
        ZStack(alignment: .trailing) {
            if isSelected {
                // The shown item's title opens its actions; the rest of the tab is its handle (`TabDragHandle`).
                HStack(spacing: 7) {
                    mark.frame(width: 16, height: 16).allowsHitTesting(false)
                    selectedTitle()
                    Spacer(minLength: 2)
                }
                .padding(.leading, 9)
                .padding(.trailing, showsClose ? 26 : 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TabDragHandle().help(helpText) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(.isSelected)
            } else {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        mark
                            .frame(width: 16, height: 16)
                        if showsTitle {
                            Text(tab.title)
                                .font(.parity(.control, weight: tab.hasUnreadUpdate ? .semibold : .regular,
                                              scale: interfaceScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                            if let status = tab.status, !showsClose {
                                SidebarTaskStatusView(status: status)
                            }
                        }
                    }
                    .padding(.leading, showsTitle ? 9 : 0)
                    .padding(.trailing, showsClose ? 26 : (showsTitle ? 7 : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .help(helpText)
                .accessibilityLabel(tab.title)
                .accessibilityValue(tab.status?.accessibilityName ?? "")
            }

            if showsClose {
                // ⌘W closes the shown tab only.
                ParityTabCloseButton(help: ShortcutHelp.text(L10n.string("Close tab"),
                                                             isSelected ? MacShortcut.closeTab.binding : nil),
                                     accessibilityLabel: L10n.format("Close tab %@", tab.title), action: onClose)
                    .padding(.trailing, 3)
            }
        }
        .frame(height: WindowTabMetrics.tabHeight)
        .background { WindowTabGround(isSelected: isSelected, isHovering: isHovering, showsDivider: showsDivider) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.string("Close tab"), action: onClose).disabled(!canClose)
            Button(L10n.string("Close Other Tabs"), action: onCloseOthers).disabled(!canClose)
        }
        .windowDraggable(.windowTab(tab.id), preview: preview)
    }

    private var preview: WindowDragPreview {
        switch tab.kind {
        case .newTask: WindowDragPreview(title: tab.title, systemName: "square.and.pencil")
        case let .task(harness): WindowDragPreview(title: tab.title, harness: harness)
        case let .split(isVertical):
            WindowDragPreview(title: tab.title, systemName: isVertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch tab.kind {
        case .newTask:
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
        case let .task(harness):
            HarnessIdentityIcon(harness: harness, size: 14)
        case let .split(isVertical):
            Image(systemName: isVertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                .font(.system(size: 11 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var helpText: String {
        var lines = [tab.title]
        if case let .task(harness) = tab.kind { lines.append(harness.displayName) }
        if let status = tab.status { lines.append(status.accessibilityName) }
        return lines.joined(separator: "\n")
    }
}

/// A tab's ground in the window's tab bar. The shown tab stands on the canvas with rounded top corners and a
/// hairline edge that curves out into the bar's bottom edge, so it runs into the header below without a line,
/// as a browser's shown tab runs into its page. Another tab shows the hover fill under the pointer, and a
/// hairline parts it from the tab before it.
private struct WindowTabGround: View {
    let isSelected: Bool
    let isHovering: Bool
    let showsDivider: Bool

    var body: some View {
        if isSelected {
            ZStack {
                WindowTabShape(closesBottom: true).fill(ParityTheme.canvas)
                WindowTabShape(closesBottom: false)
                    .stroke(ParityTheme.separator, lineWidth: 1)
                    // The edge's ends lie on the bar's own bottom line.
                    .offset(y: -0.5)
            }
        } else {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? ParityTheme.hoverFill : .clear)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                if showsDivider, !isHovering {
                    Rectangle().fill(ParityTheme.strongSeparator)
                        .frame(width: 1)
                        .padding(.vertical, 9)
                        .offset(x: -0.5)
                }
            }
        }
    }
}

/// The shown tab's outline: rounded at the top and open at the bottom, where its sides curve out into the
/// bar's bottom edge. The curves reach `WindowTabMetrics.footRadius` past the tab on each side.
struct WindowTabShape: Shape {
    /// Closed along the bottom for the fill; open for the edge, which the header below continues.
    var closesBottom: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(WindowTabMetrics.cornerRadius, rect.height / 2)
        let foot = WindowTabMetrics.footRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - foot, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - foot), radius: foot)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - foot))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX + foot, y: rect.maxY), radius: foot)
        if closesBottom { path.closeSubpath() }
        return path
    }
}
