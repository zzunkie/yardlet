import AppKit
import SwiftUI

struct TaskWorkspaceMetrics: Equatable {
    let chatWidth: CGFloat
    let trailingWidth: CGFloat
    let upperHeight: CGFloat
    let terminalHeight: CGFloat
    let showsChat: Bool
    /// The session rail's room beside the conversation: the rail's width where it shows, else 0.
    var railWidth: CGFloat = 0
    /// The task's area has room for the rail beside the conversation (`SessionRailPlacement`),
    /// whether or not the window's switch shows it.
    var railFits = false
    /// Where the open side panel stands; nil while it is closed.
    var panelPlacement: SidePanelPlacement?
    /// How far a side panel floating over the area's edge reaches over the conversation, which keeps
    /// its minimum width beneath it.
    var conversationCover: CGFloat = 0
    /// The margin a floating panel keeps from the area's top, trailing and bottom edges; 0 where it
    /// does not float.
    var panelInset: CGFloat = 0

    var showsRail: Bool { railWidth > 0 }

    /// Lower than this on a drag, the terminal closes: the Codex app's bottom panel closes below half
    /// its 160 minimum (`Rk(160)`) and keeps the height it had.
    static let terminalClosingHeight: CGFloat = 80

    /// What a divider drag does: closes the panel, or gives it a size within its bounds.
    enum DragOutcome: Equatable {
        case close
        case size(CGFloat)
    }

    /// The side panel's divider moved `translation` (rightward positive) from a panel `start` wide.
    static func sidePanelDrag(from start: CGFloat, by translation: CGFloat, areaWidth: CGFloat) -> DragOutcome {
        let proposed = start - translation
        if proposed < SidePanelWidth.closingWidth { return .close }
        return .size(SidePanelWidth.clamped(proposed, areaWidth: areaWidth))
    }

    /// The terminal's divider moved `translation` (downward positive) from a terminal `start` high.
    static func terminalDrag(from start: CGFloat, by translation: CGFloat, availableHeight: CGFloat,
                             trailing: Bool, interfaceScale: CGFloat = 1) -> DragOutcome {
        let proposed = start - translation
        if proposed < terminalClosingHeight { return .close }
        return .size(constrainedTerminalHeight(proposed, availableHeight: availableHeight, trailing: trailing,
                                               interfaceScale: interfaceScale))
    }

    /// - Parameter rail: the window's rail switch is on, so the rail takes its column where it fits.
    static func resolve(size: CGSize, trailing: Bool, terminal: Bool, preferredWidth: CGFloat, preferredHeight: CGFloat,
                        expanded: Bool = false, interfaceScale: CGFloat = 1, rail: Bool = false) -> Self {
        let placement = trailing ? SidePanelPlacement(areaWidth: size.width, expanded: expanded) : nil
        let inset = placement?.floats == true ? SidePanelWidth.floatingInset : 0
        let panelWidth: CGFloat = switch placement {
        case nil: 0
        case .beside: SidePanelWidth.clamped(preferredWidth, areaWidth: size.width)
        case .over: SidePanelWidth.minimum
        case .sheet: max(0, size.width - SidePanelWidth.sheetPeek - inset)
        case .inPlace: size.width
        }
        // What the panel takes of the area's width, with its margin from the trailing edge.
        let panelFootprint = panelWidth + inset
        let terminalHeight = terminal ? constrainedTerminalHeight(
            preferredHeight, availableHeight: size.height, trailing: trailing, interfaceScale: interfaceScale
        ) : 0
        // The conversation's side of the area: the whole area, what a panel beside it and its divider
        // leave, under a floating panel up to the panel and never less than the conversation's minimum,
        // or behind a sheet the whole area it showed at before the panel opened.
        let sessionWidth: CGFloat = switch placement {
        case nil, .sheet: size.width
        case .beside: size.width - panelWidth - SidePanelWidth.divider
        case .over: max(size.width - panelFootprint, SidePanelWidth.conversationShare)
        case .inPlace: 0
        }
        // A floating panel stands where the rail would.
        let railFits = (placement == nil || placement == .beside)
            && SessionRailPlacement.fits(sessionWidth: sessionWidth, panelOpen: trailing)
        let railWidth = rail && railFits ? SessionRailPlacement.width : 0
        return Self(
            chatWidth: sessionWidth - railWidth,
            trailingWidth: panelWidth,
            upperHeight: max(0, size.height - terminalHeight - (terminal ? 6 : 0)),
            terminalHeight: terminalHeight,
            showsChat: placement != .inPlace,
            railWidth: railWidth,
            railFits: railFits,
            panelPlacement: placement,
            conversationCover: placement == .over ? max(0, sessionWidth - (size.width - panelFootprint)) : 0,
            panelInset: inset
        )
    }

    static func constrainedTerminalHeight(
        _ preferred: CGFloat, availableHeight: CGFloat, trailing: Bool, interfaceScale: CGFloat = 1
    ) -> CGFloat {
        let available = max(0, availableHeight - 6)
        // Leave readable content beneath review controls or above the conversation composer.
        // Short windows share the remaining room while keeping the terminal usable.
        let readingHeight = (trailing ? 320.0 : 280.0) * interfaceScale
        let minimum = TaskWorkspaceSizes.minimumTerminalHeight
        let upperMinimum = min(readingHeight, max(0, available - minimum))
        return min(max(minimum, preferred), available - upperMinimum)
    }
}

/// Where an open side panel stands in the task's area.
enum SidePanelPlacement: Equatable {
    /// Beside the conversation, which keeps its minimum width (`TaskWorkspaceSizes.minimumConversationWidth`).
    case beside
    /// Floating over the area's trailing edge at the panel's minimum width, where the conversation
    /// at its minimum and the panel do not fit side by side: the conversation runs up to the panel,
    /// and where that would narrow it past its minimum it keeps its minimum under the panel's edge.
    /// The rail has no room.
    case over
    /// Floating as a sheet over most of an area narrower than the Codex app's conversation share and
    /// panel minimum, where a panel at its minimum would leave too little of the conversation to work
    /// from: the conversation's leading edge shows behind it, dimmed, and a click there or Escape closes
    /// the panel.
    case sheet
    /// In the conversation's place, at any width: the panel's expand button.
    case inPlace

    init(areaWidth: CGFloat, expanded: Bool) {
        if expanded {
            self = .inPlace
        } else if areaWidth < SidePanelWidth.conversationInView {
            self = .sheet
        } else {
            self = areaWidth >= SidePanelWidth.besideConversation ? .beside : .over
        }
    }

    /// Floating over the conversation, as a rounded, edged and shadowed card inset from the area's edges.
    var floats: Bool { self == .over || self == .sheet }
}

/// The side panel's width, as the Codex app sizes its right panel (ChatGPT.app 26.1016 `EZt`, `DZt`,
/// `AZt`, `jZt`): at least 320, kept as a share of the room above that so a dragged width follows the
/// window, and until it is dragged the Codex app's default for the room the task has. Beside it the
/// conversation keeps its own minimum, wider than the Codex app's 352 (`zZt`). The task's area is what
/// the Codex app calls the main content: the window beside the sidebar, or one pane of a split view.
enum SidePanelWidth {
    static let minimum: CGFloat = 320
    /// What the conversation keeps beside the panel.
    static let conversationShare: CGFloat = TaskWorkspaceSizes.minimumConversationWidth
    static let divider: CGFloat = 6
    /// Narrower than this on a drag, the panel closes, as the Codex app's does below half its minimum
    /// (`Rk(320)`); widened again it would open. The width it had is kept.
    static let closingWidth: CGFloat = 160
    /// The narrowest area that shows the conversation at its minimum beside the narrowest panel; a
    /// narrower one floats the panel over the conversation's edge (`SidePanelPlacement.over`).
    static let besideConversation: CGFloat = minimum + divider + conversationShare
    /// The narrowest area that keeps the conversation in view while the panel is open: the Codex app's
    /// 320 and 352 (`zZt`) and the divider. A narrower one shows the panel as a sheet over it.
    static let conversationInView: CGFloat = minimum + 352 + divider
    /// The margin a floating panel keeps from the area's top, trailing and bottom edges, as the rail
    /// raised in a narrow window keeps (`SessionRailRaisedLayer`).
    static let floatingInset: CGFloat = ParitySpace.s8
    /// What of the conversation shows beside a panel floating as a sheet (`SidePanelPlacement.sheet`).
    static let sheetPeek: CGFloat = ParitySpace.s48

    static func maximum(areaWidth: CGFloat) -> CGFloat {
        max(minimum, areaWidth - divider - conversationShare)
    }

    static func clamped(_ width: CGFloat, areaWidth: CGFloat) -> CGFloat {
        min(max(minimum, width), maximum(areaWidth: areaWidth))
    }

    /// The Codex app's default (`EZt`): max(320, min(window height × 1.6, area − 500), min(640, area − 352)),
    /// within what leaves the conversation its minimum. Where the window shows the rail and the area
    /// has room for it beside the panel, the default leaves it that room (`SessionRailPlacement`), so
    /// opening the panel does not push the rail over the conversation.
    static func standard(areaWidth: CGFloat, windowHeight: CGFloat, keepsRail: Bool) -> CGFloat {
        var width = max(minimum, min(windowHeight * 1.6, areaWidth - 500), min(640, areaWidth - 352))
        if keepsRail {
            let besideRail = areaWidth - divider - SessionRailPlacement.minimumBesidePanelWidth
            if besideRail >= minimum { width = min(width, besideRail) }
        }
        return clamped(width, areaWidth: areaWidth)
    }

    static func width(ratio: Double, areaWidth: CGFloat) -> CGFloat {
        minimum + CGFloat(min(max(0, ratio), 1)) * (maximum(areaWidth: areaWidth) - minimum)
    }

    static func ratio(width: CGFloat, areaWidth: CGFloat) -> Double {
        let room = maximum(areaWidth: areaWidth) - minimum
        guard room > 0 else { return 0 }
        return Double((clamped(width, areaWidth: areaWidth) - minimum) / room)
    }

    /// What the panel opens at: the dragged share, else a width an earlier build saved, else the default.
    static func resolve(_ preferences: TaskWorkspacePreferences, areaWidth: CGFloat, windowHeight: CGFloat,
                        keepsRail: Bool) -> CGFloat {
        if let ratio = preferences.panelWidthRatio { return width(ratio: ratio, areaWidth: areaWidth) }
        if preferences.panelWidth != TaskWorkspaceSizes.defaultPanelWidth {
            return clamped(preferences.panelWidth, areaWidth: areaWidth)
        }
        return standard(areaWidth: areaWidth, windowHeight: windowHeight, keepsRail: keepsRail)
    }
}

private struct TaskWindowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

/// The header row of a task's area: the window's title bar for the task a tab shows, a split pane's
/// header for the pane's task. The area draws it over its conversation side, and while the side panel
/// stands beside the conversation the panel reaches the area's top and its tab strip takes the rest of
/// the row, as the Codex app's right panel puts its tab row in the title bar over the panel's column.
struct TaskAreaHeader {
    var height: CGFloat
    /// The window's title bar: the empty part of the panel's tab strip there moves the window.
    var isTitleBar: Bool
    var content: AnyView
}

/// The row a side panel's tab strip is drawn in when it shares the area's header row.
struct WorkSurfaceHeaderRow: Equatable {
    var height: CGFloat
    var isTitleBar: Bool
}

private struct TaskAreaHeaderKey: EnvironmentKey {
    static var defaultValue: TaskAreaHeader? { nil }
}

private struct WorkSurfaceHeaderRowKey: EnvironmentKey {
    static let defaultValue: WorkSurfaceHeaderRow? = nil
}

private struct ConversationTrailingCoverKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The window's height, which the side panel's default width reads as the Codex app reads its shell's.
    var taskWindowHeight: CGFloat? {
        get { self[TaskWindowHeightKey.self] }
        set { self[TaskWindowHeightKey.self] = newValue }
    }

    /// The header the task's area draws at its top; nil draws none.
    var taskAreaHeader: TaskAreaHeader? {
        get { self[TaskAreaHeaderKey.self] }
        set { self[TaskAreaHeaderKey.self] = newValue }
    }

    /// How far a side panel floating over the area's edge reaches over the conversation, which keeps
    /// its width beneath it (`TaskWorkspaceMetrics.conversationCover`). What the conversation is worked
    /// from, its composer and its find bar, keeps clear of it.
    var conversationTrailingCover: CGFloat {
        get { self[ConversationTrailingCoverKey.self] }
        set { self[ConversationTrailingCoverKey.self] = newValue }
    }

    /// Set for the side panel while its tab strip shares the area's header row.
    var workSurfaceHeaderRow: WorkSurfaceHeaderRow? {
        get { self[WorkSurfaceHeaderRowKey.self] }
        set { self[WorkSurfaceHeaderRowKey.self] = newValue }
    }
}

/// Keeps what the conversation is worked from clear of a side panel floating over its edge.
private struct ClearOfFloatingPanel: ViewModifier {
    @Environment(\.conversationTrailingCover) private var cover

    func body(content: Content) -> some View {
        content.padding(.trailing, cover)
    }
}

extension View {
    /// Narrows the view by how far a floating side panel reaches over the conversation.
    func clearOfFloatingPanel() -> some View {
        modifier(ClearOfFloatingPanel())
    }
}

/// The chat stays in the same structural position while panels open, close, and resize.
/// Hiding it at compact widths preserves its draft and reading state without accepting input.
/// The session rail, where the window shows it and the area has room, is a fixed column between
/// the conversation and the side panel, as the Claude app puts its rail beside the conversation and
/// its side panes after it. The area's header (`taskAreaHeader`) runs over the conversation and the
/// rail; the side panel beside them reaches the top, its tab strip in the header's row. A panel
/// floating over the area's edge (`SidePanelPlacement.over`), as a sheet over a narrow area
/// (`SidePanelPlacement.sheet`) or in the conversation's place sits below the header, which then runs
/// the whole width.
struct TaskWorkspaceLayout<Chat: View, Rail: View, Trailing: View, Bottom: View>: View {
    let showsTrailing: Bool
    let showsTerminal: Bool
    @Binding var preferences: TaskWorkspacePreferences
    /// The window's rail switch.
    var wantsRail = false
    /// Told whether the area has room for the rail, as it resizes and panels open.
    var onRailFitChange: (Bool) -> Void = { _ in }
    let onReturnToChat: () -> Void
    /// A drag narrows the side panel past `SidePanelWidth.closingWidth`.
    var onCloseTrailing: () -> Void = {}
    /// A drag lowers the terminal past `TaskWorkspaceMetrics.terminalClosingHeight`.
    var onCloseTerminal: () -> Void = {}
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let rail: () -> Rail
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let bottom: () -> Bottom
    @State private var startingWidth: CGFloat?
    @State private var startingHeight: CGFloat?
    /// The sizes when a drag began, kept again if the drag closes a panel.
    @State private var startingPreferences: TaskWorkspacePreferences?
    /// The conversation's width when it last showed, which it keeps while the panel stands in its place. Held by
    /// reference, as no view draws it: a resize changes it at each frame.
    @State private var shownChat = ShownChatWidth()
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskWindowHeight) private var windowHeight
    @Environment(\.taskAreaHeader) private var header
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let headerHeight = header?.height ?? 0
            // Below the header: what the conversation, the panel in its place and the terminal share.
            let below = CGSize(width: proxy.size.width, height: max(0, proxy.size.height - headerHeight))
            let panelWidth = SidePanelWidth.resolve(
                preferences, areaWidth: proxy.size.width, windowHeight: windowHeight ?? proxy.size.height,
                keepsRail: wantsRail)
            let metrics = TaskWorkspaceMetrics.resolve(
                size: below, trailing: showsTrailing, terminal: showsTerminal,
                preferredWidth: panelWidth, preferredHeight: preferences.terminalHeight,
                expanded: preferences.isExpanded, interfaceScale: interfaceScale, rail: wantsRail
            )
            // The panel beside the conversation reaches the top and shares the header's row.
            let panelInRow = header != nil && metrics.panelPlacement == .beside
            let trailingTop = panelInRow ? 0 : headerHeight
            let floats = metrics.panelPlacement?.floats == true
            // Behind a sheet the conversation shows its edge but is not worked from: a click on it closes the panel.
            let behindSheet = metrics.panelPlacement == .sheet
            let chatIsActive = metrics.showsChat && !behindSheet
            // Under the panel in its place or behind a sheet, the conversation keeps the width it last showed at; in its
            // place it takes no room, and behind a sheet it is clipped to the area. Given
            // none, it laid each of its turns out again at a width it never shows at, and again once it showed.
            let chatWidth = shownChat.width(for: metrics, areaWidth: below.width)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        HStack(spacing: 0) {
                            chat()
                                .frame(width: chatWidth, height: metrics.upperHeight)
                                .frame(width: metrics.showsChat ? (behindSheet ? below.width : chatWidth) : 0, alignment: .leading)
                                .contentShape(Rectangle()).clipped().opacity(metrics.showsChat ? 1 : 0)
                                .disabled(!chatIsActive).allowsHitTesting(chatIsActive)
                                .accessibilityHidden(!chatIsActive)
                                .environment(\.conversationTrailingCover, metrics.conversationCover)
                                .overlay {
                                    if behindSheet {
                                        Rectangle().fill(.black.opacity(colorScheme == .dark ? 0.32 : 0.12))
                                            .contentShape(Rectangle())
                                            .onTapGesture(perform: onReturnToChat)
                                            .accessibilityHidden(true)
                                    }
                                }
                            if metrics.showsRail {
                                rail()
                                    .frame(width: metrics.railWidth, height: metrics.upperHeight)
                                    .clipped()
                            }
                        }
                        .padding(.top, headerHeight)
                        // A floating panel takes no room from the conversation, which keeps its width under the
                        // panel's edge rather than narrowing past its minimum.
                        .frame(width: floats ? max(0, proxy.size.width - metrics.trailingWidth - metrics.panelInset) : nil,
                               alignment: .leading)
                        if showsTrailing {
                            if metrics.panelPlacement == .beside {
                                resizeHandle(vertical: true)
                                    .frame(height: metrics.upperHeight + headerHeight - trailingTop)
                                    .padding(.top, trailingTop)
                                    // Measured in the window: the handle moves with the panel, and a
                                    // translation measured from the handle followed the pointer at half speed.
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            if startingWidth == nil {
                                                startingWidth = metrics.trailingWidth
                                                startingPreferences = preferences
                                            }
                                            guard value.translation.width != 0, let start = startingWidth else { return }
                                            switch TaskWorkspaceMetrics.sidePanelDrag(
                                                from: start, by: value.translation.width, areaWidth: proxy.size.width) {
                                            case .close: closeOnDrag(onCloseTrailing)
                                            case let .size(width): setPanelWidth(width, areaWidth: proxy.size.width)
                                            }
                                        }.onEnded { _ in endDrag() })
                                    // A double click returns the panel to the default width, as the Codex app's divider does.
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        preferences.panelWidthRatio = nil
                                        preferences.panelWidth = TaskWorkspaceSizes.defaultPanelWidth
                                    })
                                    .accessibilityLabel(L10n.string("Resize side panel"))
                                    .accessibilityAdjustableAction { direction in
                                        setPanelWidth(metrics.trailingWidth + (direction == .increment ? 30 : -30),
                                                      areaWidth: proxy.size.width)
                                    }
                            }
                            VStack(spacing: 0) {
                                if !metrics.showsChat {
                                    Button(action: onReturnToChat) {
                                        Label(L10n.string("Back to conversation"), systemImage: "chevron.left")
                                    }
                                    .buttonStyle(.borderless).parityPointer().font(.callout)
                                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    Divider()
                                }
                                trailing()
                                    .environment(\.workSurfaceExpansion, $preferences.isExpanded)
                                    .environment(\.workSurfaceHeaderRow, panelInRow ? header.map {
                                        WorkSurfaceHeaderRow(height: $0.height, isTitleBar: $0.isTitleBar)
                                    } : nil)
                            }
                            .frame(width: metrics.trailingWidth,
                                   height: max(0, metrics.upperHeight + headerHeight - trailingTop - 2 * metrics.panelInset))
                            .contentShape(Rectangle())
                            // Floating, it is a card as the rail raised in a narrow window is (`SessionRailRaisedLayer`).
                            // It stays the same view either way, so what it shows is kept.
                            .floatingSurface(floats)
                            // Escape puts a sheet away, as a click beside it does.
                            .onMacShortcutExit(perform: behindSheet ? onReturnToChat : nil)
                            .padding([.top, .trailing, .bottom], metrics.panelInset)
                            .padding(.top, trailingTop)
                        }
                    }
                    .frame(height: metrics.upperHeight + headerHeight, alignment: .top)
                    if showsTerminal {
                        resizeHandle(vertical: false)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if startingHeight == nil {
                                        startingHeight = metrics.terminalHeight
                                        startingPreferences = preferences
                                    }
                                    guard value.translation.height != 0, let start = startingHeight else { return }
                                    switch TaskWorkspaceMetrics.terminalDrag(
                                        from: start, by: value.translation.height, availableHeight: below.height,
                                        trailing: showsTrailing, interfaceScale: interfaceScale) {
                                    case .close: closeOnDrag(onCloseTerminal)
                                    case let .size(height): preferences.terminalHeight = height
                                    }
                                }.onEnded { _ in endDrag() })
                            // A double click returns the terminal to its default height, as the Codex app's divider does.
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                preferences.terminalHeight = TaskWorkspaceSizes.defaultTerminalHeight
                            })
                            .accessibilityLabel(L10n.string("Resize terminal"))
                            .accessibilityAdjustableAction { direction in
                                preferences.terminalHeight = TaskWorkspaceMetrics.constrainedTerminalHeight(
                                    metrics.terminalHeight + (direction == .increment ? 30 : -30),
                                    availableHeight: below.height, trailing: showsTrailing, interfaceScale: interfaceScale
                                )
                            }
                        bottom().frame(height: metrics.terminalHeight).contentShape(Rectangle()).clipped()
                    }
                }
                // What the area holds draws no header of its own.
                .environment(\.taskAreaHeader, nil)
                // The header keeps its place in the view tree whether the panel shares its row or not.
                if let header {
                    header.content
                        .frame(width: panelInRow ? metrics.chatWidth + metrics.railWidth : proxy.size.width,
                               height: header.height)
                        .environment(\.taskAreaHeader, nil)
                }
            }
            .onChange(of: metrics.railFits, initial: true) { _, fits in onRailFitChange(fits) }
            // A width an earlier build saved becomes a share of this area the first time the panel shows.
            .onChange(of: showsTrailing && preferences.panelWidthRatio == nil
                        && preferences.panelWidth != TaskWorkspaceSizes.defaultPanelWidth, initial: true) { _, carries in
                guard carries else { return }
                preferences.panelWidthRatio = SidePanelWidth.ratio(width: preferences.panelWidth, areaWidth: proxy.size.width)
            }
        }
        .onChange(of: showsTrailing) { _, shown in
            if !shown {
                preferences.isExpanded = false
                startingWidth = nil
            }
        }
        .onChange(of: showsTerminal) { _, shown in
            if !shown { startingHeight = nil }
        }
    }

    /// Keeps the dragged width as the Codex app does, as a share of the area's room, and the width
    /// itself for a build before the share.
    private func setPanelWidth(_ width: CGFloat, areaWidth: CGFloat) {
        let width = SidePanelWidth.clamped(width, areaWidth: areaWidth)
        preferences.panelWidthRatio = SidePanelWidth.ratio(width: width, areaWidth: areaWidth)
        preferences.panelWidth = Double(width)
    }

    /// A drag past the closing size closes the panel and keeps the size it had before the drag.
    private func closeOnDrag(_ close: () -> Void) {
        if let startingPreferences { preferences = startingPreferences }
        endDrag()
        close()
    }

    private func endDrag() {
        startingWidth = nil
        startingHeight = nil
        startingPreferences = nil
    }

    private func resizeHandle(vertical: Bool) -> some View {
        Color.clear
            .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
            .overlay {
                Rectangle().fill(ParityTheme.separator)
                    .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .accessibilityElement()
    }
}

/// The width the conversation last showed at (`TaskWorkspaceLayout`).
private final class ShownChatWidth {
    private var width: CGFloat?

    /// The width to lay the conversation out at: the one it shows at, or while hidden or behind a sheet
    /// (`SidePanelPlacement.sheet`) the last it showed at, else the area's.
    func width(for metrics: TaskWorkspaceMetrics, areaWidth: CGFloat) -> CGFloat {
        if metrics.showsChat, metrics.panelPlacement != .sheet { width = max(0, metrics.chatWidth) }
        return width ?? areaWidth
    }
}

/// A surface floating over the task's area: the side panel over the conversation's edge or as a sheet,
/// and the rail raised in a narrow window. A card inset from the area's edges, with the surface radius,
/// the elevated fill, a hairline edge and a soft shadow that falls from a plain shape behind it, not from
/// what the surface shows. Off, it is a plain clipped rectangle and stays the same view.
private struct FloatingSurface: ViewModifier {
    let isFloating: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isFloating ? ParityRadius.surface : 0, style: .continuous)
        let dark = colorScheme == .dark
        content
            .clipShape(shape)
            .overlay {
                if isFloating {
                    shape.strokeBorder(dark ? ParityTheme.strongSeparator : ParityTheme.separator, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if isFloating {
                    shape.fill(ParityTheme.elevated)
                        .shadow(color: .black.opacity(dark ? 0.30 : 0.06), radius: 2, y: 1)
                        .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 18, y: 8)
                }
            }
    }
}

extension View {
    /// Draws the view as a card floating over the task's area (`FloatingSurface`) while `isFloating`.
    func floatingSurface(_ isFloating: Bool = true) -> some View {
        modifier(FloatingSurface(isFloating: isFloating))
    }
}
