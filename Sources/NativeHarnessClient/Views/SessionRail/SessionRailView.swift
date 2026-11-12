import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a task's rail can ask of the window and the app.
@MainActor
struct SessionRailActions {
    /// A Settings card choice, applied as the composer applies it.
    var onChoose: (ComposerSessionChoice) -> Void = { _ in }
    /// Reads choices a control does not have yet (a detached task's settings, a model list).
    var onPrepareSettings: () async -> Void = {}
    /// Opens the task's account choice, where the harness can switch accounts.
    var chooseAccount: (() -> Void)? = nil
    /// The context window's "Compact session".
    var compact: ComposerContextUsageDetails.Compact? = nil
    /// Yardlet's connectors: this task's switches, "Reconnect" and Settings › Connectors.
    var connectors: ComposerConnectorEnvironment? = nil
    var refreshConnectors: () async -> Void = {}
    /// The background tasks' open and stop controls.
    var backgroundTasks: HarnessActivityActions? = nil
    /// Opens a background shell's or monitor's output beside the task.
    var openTaskOutput: ((HarnessActivity) -> Void)? = nil
    /// Codex's background terminals: their output and stopping them.
    var terminals: SessionRailTerminalActions? = nil
    /// Opens a schedule that continues the task in Scheduled tasks.
    var openSchedule: ((UUID) -> Void)? = nil
    /// The Agents card's controls.
    var agents: SessionRailAgentActions? = nil
    /// Opens the browser panel, from the Preview card.
    var openBrowser: (() -> Void)? = nil
    /// Opens the review panel on the task's changes.
    var openChanges: () -> Void = {}
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// The Changes card's pull request controls.
    var pullRequest: SessionRailPullRequestActions? = nil
}

/// What the Changes card's pull request can ask for. Writes run only from these, which only the
/// person's presses call.
@MainActor
struct SessionRailPullRequestActions {
    var refresh: () -> Void = {}
    var loadLog: (PullRequestDetail.Check) -> Void = { _ in }
    var closeLog: (PullRequestDetail.Check) -> Void = { _ in }
    var rerunFailed: ([PullRequestDetail.Check]) -> Void = { _ in }
    var requestMerge: (PullRequestMergeRequest.Kind) -> Void = { _ in }
    var confirmMerge: () -> Void = {}
    var cancelMerge: () -> Void = {}
    /// The task's auto-fix switch, and the answer to the question.
    var setAutoFix: (Bool) -> Void = { _ in }
    /// "Fix CI": puts the request in the task's composer.
    var draftFix: (String) -> Void = { _ in }
}

/// A task's session rail, the Claude app's Code tab "Session details" rail: a fixed 280 pt column of
/// cards beside the conversation (`SessionRailPlacement`), or raised over the task's trailing edge
/// where the task's area has no room. Each card folds from its header (Option-click folds or opens
/// them all); a header's menu shows or hides cards and resets them, and a header drags to reorder.
struct SessionRailView: View {
    let content: SessionRailContent
    @Binding var folds: SessionRailFolds
    let preferences: SessionRailPreferenceStore
    var actions = SessionRailActions()
    /// Raised over the task rather than beside the conversation: it draws its own edge and shadow.
    var isRaised = false

    @State private var draggedKind: SessionRailCardKind?
    @State private var dropTarget: SessionRailCardKind?

    private var cards: [SessionRailCardKind] { content.cards(preferences.preferences) }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.sessionRail)
#endif
        ScrollView(.vertical) {
            VStack(spacing: SessionRailPlacement.cardSpacing) {
                ForEach(cards) { kind in
                    SessionRailCard(
                        kind: kind,
                        rollup: content.rollup(kind),
                        meter: content.meter(kind),
                        isFolded: folds.isFolded(kind),
                        isDropTarget: dropTarget == kind && draggedKind != kind,
                        onToggle: { toggle(kind) },
                        menu: { headerMenu },
                        moveUp: canMove(kind, by: -1) ? { move(kind, by: -1) } : nil,
                        moveDown: canMove(kind, by: 1) ? { move(kind, by: 1) } : nil,
                        dragItem: {
                            draggedKind = kind
                            return NSItemProvider(object: kind.rawValue as NSString)
                        }
                    ) {
                        SessionRailCardBody(kind: kind, content: content, actions: actions)
                    }
                    .onDrop(of: [UTType.plainText], delegate: SessionRailDropDelegate(
                        target: kind, dragged: $draggedKind, dropTarget: $dropTarget,
                        onDrop: { dragged in preferences.update { $0.move(dragged, before: kind) } }))
                }
            }
            // The cards take the column's width, whatever their content would like.
            .frame(width: SessionRailPlacement.width - (isRaised ? 12 : 4) - 12)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .padding(.leading, isRaised ? 12 : 4)
            .padding(.trailing, 12)
        }
        .scrollIndicators(.automatic)
        .frame(width: SessionRailPlacement.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ParityTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Session details"))
    }

    private func toggle(_ kind: SessionRailCardKind) {
        let folding = !folds.isFolded(kind)
        if NSEvent.modifierFlags.contains(.option) {
            folds.setAll(folded: folding)
        } else {
            folds.setFolded(kind, folding)
        }
    }

    private func canMove(_ kind: SessionRailCardKind, by offset: Int) -> Bool {
        guard let index = cards.firstIndex(of: kind) else { return false }
        return cards.indices.contains(index + offset)
    }

    private func move(_ kind: SessionRailCardKind, by offset: Int) {
        let shown = cards
        preferences.update { $0.move(kind, by: offset, among: shown) }
    }

    /// "Show ▸" the cards that can be hidden, then "Reset to defaults" (`HEqkWq/cPs`, `JT3r1TFEIO`).
    @ViewBuilder private var headerMenu: some View {
        Menu(L10n.string("Show")) {
            ForEach(SessionRailCardKind.allCases.filter { $0.canHide && Self.drawnKinds.contains($0) }) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { !preferences.preferences.isHidden(kind) },
                    set: { shown in preferences.update { $0.setHidden(kind, !shown) } }))
            }
        }
        Divider()
        Button(L10n.string("Reset to defaults")) {
            preferences.update { $0.reset() }
            folds = SessionRailFolds()
        }
    }

    /// The cards this build can fill; the rest are not offered in "Show".
    static let drawnKinds: Set<SessionRailCardKind> = [
        .environment, .settings, .context, .usage, .connectors, .progress, .outputs, .changes, .suggestions,
        .agents, .backgroundTasks, .preview
    ]
}

/// Moves a dragged card before the card it is dropped on.
private struct SessionRailDropDelegate: DropDelegate {
    let target: SessionRailCardKind
    @Binding var dragged: SessionRailCardKind?
    @Binding var dropTarget: SessionRailCardKind?
    let onDrop: (SessionRailCardKind) -> Void

    func dropEntered(info: DropInfo) { dropTarget = target }

    func dropExited(info: DropInfo) { if dropTarget == target { dropTarget = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragged = nil
            dropTarget = nil
        }
        guard let dragged, dragged != target else { return false }
        onDrop(dragged)
        return true
    }
}

/// One card: a header with its title, a chevron and — folded — its rollup and meter on the right; the
/// header folds and opens it. The Claude app's `Xv`, in Yardlet's card look (1 pt separator border,
/// radius 10).
struct SessionRailCard<HeaderMenu: View, Content: View>: View {
    let kind: SessionRailCardKind
    let rollup: String?
    let meter: Double?
    let isFolded: Bool
    var isDropTarget = false
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> HeaderMenu
    var moveUp: (() -> Void)? = nil
    var moveDown: (() -> Void)? = nil
    /// What dragging the header carries, to drop on another card. Only the header drags, so text in
    /// a card (a failed log) stays selectable.
    var dragItem: () -> NSItemProvider = { NSItemProvider() }
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isFolded {
                content()
                    .font(.system(size: 12 * interfaceScale))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTarget ? Color.accentColor.opacity(0.6) : ParityTheme.separator,
                        lineWidth: isDropTarget ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(kind.title)
                    .font(.system(size: 12 * interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if isFolded {
                    if let rollup {
                        Text(rollup)
                            .font(.system(size: 11.5 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let meter {
                        SessionRailMeter(fraction: meter)
                            .frame(width: 28, height: 4)
                    }
                }
                if isHovering {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9 * interfaceScale, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help(L10n.format("Reorder %@", kind.title))
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * interfaceScale, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 34 * interfaceScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .onDrag(dragItem)
        .accessibilityLabel(kind.title)
        .accessibilityValue(isFolded ? [L10n.string("Collapsed"), rollup].compactMap { $0 }.joined(separator: ", ")
                                     : L10n.string("Expanded"))
        .accessibilityHint(L10n.string("Option-click folds or opens every card"))
        .modifier(SessionRailMoveActions(title: kind.title, moveUp: moveUp, moveDown: moveDown))
    }
}

/// "Move up" and "Move down" for VoiceOver and keyboard users, who cannot drag.
private struct SessionRailMoveActions: ViewModifier {
    let title: String
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text(L10n.format("Move %@ up", title))) { moveUp?() }
            .accessibilityAction(named: Text(L10n.format("Move %@ down", title))) { moveDown?() }
    }
}

/// The small meter beside a folded card's rollup.
struct SessionRailMeter: View {
    let fraction: Double
    var tint: Color = .secondary

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ParityTheme.selectedFill)
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A row in a card: an icon, a title, and a quieter value on the right.
struct SessionRailRow<Trailing: View>: View {
    let systemName: String?
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(systemName: String?, title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.systemName = systemName
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemName {
                Image(systemName: systemName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            trailing()
        }
        .frame(minHeight: 24)
    }
}

extension SessionRailRow where Trailing == EmptyView {
    init(systemName: String?, title: String) {
        self.init(systemName: systemName, title: title) { EmptyView() }
    }
}
