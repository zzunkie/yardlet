import AppKit
import SwiftUI

/// When a sidebar task row's hover card opens and closes. The Codex app's (26.1016) tooltip provider
/// opens a row's card 200 ms after the pointer rests on it, opens the next row's at once while one
/// is open or was closed less than 300 ms ago, and opens it at once over the row's end, where its
/// buttons are. Every interval the card uses is here, so trying another is one change.
enum SidebarHoverCardTiming {
    /// How long the pointer rests on a row before its card opens.
    static let openDelay: Duration = .milliseconds(200)
    /// How soon after a card closed the next row's opens without waiting.
    static let warmInterval: Duration = .milliseconds(300)
    /// How long a card waits for the pointer that left its row to reach it (or another row) before
    /// it closes; the Codex app keeps it while the pointer heads for it.
    static let closeGrace: Duration = .milliseconds(150)
}

/// Where the card sits beside its row, and how wide it is (the Codex app's `w-[20rem]`).
enum SidebarHoverCardMetrics {
    static let width: CGFloat = 320
    /// The gap between the row's end and the card.
    static let gap: CGFloat = 4
    /// The width at a row's end where the pointer opens the card at once: the pin and archive buttons.
    static let immediateWidth: CGFloat = 58
    /// The space the card keeps from the window's bottom edge.
    static let margin: CGFloat = 8
    /// The coordinate space rows report their frames in, the window's sidebar and content together.
    static let space = "SidebarHoverCard"
}

/// What a task row's hover card shows: the task, its place, its harness, its state and its pull
/// request, which the row's help showed before (2026-10-23 user decision: the Codex app's hover card).
struct SidebarHoverCardContent: Equatable {
    struct Status: Equatable {
        let status: SidebarTaskStatus
        /// The status's words, with the error or the limit's reset under them.
        var text: String { status.help }
    }

    let taskID: UUID
    let title: String
    let harness: HarnessKind
    /// The project the task belongs to, or nil for a chat.
    let projectName: String?
    /// The task's folder, with `~` for the home folder: its worktree's when it runs in one.
    let folder: String
    /// The worktree's name or branch, when the task runs in one.
    let worktree: String?
    let status: Status?
    let isScheduledRun: Bool
    let cpuPercent: Int?
    let pullRequest: TaskPullRequestRowMark?
    /// The account an agent's start put the task on, or a schedule's run moved it to, and why; nil
    /// for a task the person started on their own account.
    let accountName: String?
    let accountReason: String?

    init(session: SessionRecord, projectName: String?, status: SidebarTaskStatus?, isScheduledRun: Bool,
         cpuPercent: Int?, pullRequest: TaskPullRequestRowMark?, accountAssignment: AccountAssignment? = nil) {
        taskID = session.id
        title = session.title
        harness = session.harness
        self.projectName = projectName
        folder = (session.workspaceURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        worktree = SidebarWorktreeProjection.detail(for: session)
        self.status = status.map(Status.init)
        self.isScheduledRun = isScheduledRun
        self.cpuPercent = cpuPercent
        self.pullRequest = pullRequest
        accountName = accountAssignment?.accountName
        accountReason = accountAssignment?.reasonLine()
    }
}

/// The window's one sidebar hover card: which row's card is open, and the timing of opening it,
/// moving it to another row and closing it (`SidebarHoverCardTiming`). Rows report the pointer; the
/// window draws the card above the sidebar and the content beside it (`SidebarHoverCardLayer`).
@MainActor @Observable
final class SidebarHoverCardState {
    struct Card: Equatable {
        var content: SidebarHoverCardContent
        /// The row, in `SidebarHoverCardMetrics.space`.
        var rowFrame: CGRect
    }

    /// The card on screen.
    private(set) var card: Card?

    @ObservationIgnored private var hovered: Card?
    @ObservationIgnored private var isPointerInCard = false
    @ObservationIgnored private var closedAt: ContinuousClock.Instant?
    /// A row whose card a click put away: it opens again once the pointer has left it.
    @ObservationIgnored private var suppressedTaskID: UUID?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private let clock = ContinuousClock()
    /// Where the pointer rested when the sidebar scrolled under it.
    @ObservationIgnored private var restingPointer: NSPoint?
    /// The pointer's place on the screen.
    @ObservationIgnored private let pointerLocation: () -> NSPoint

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.pointerLocation = pointerLocation
    }

    /// The pointer is on a task's row, at its end where the buttons are when `atEnd`.
    func rowHovered(_ content: SidebarHoverCardContent, frame: CGRect, atEnd: Bool) {
        closing?.cancel()
        closing = nil
        if let restingPointer {
            guard pointerLocation() != restingPointer else { return }
            self.restingPointer = nil
        }
        guard suppressedTaskID != content.taskID else { return }
        let pointed = Card(content: content, rowFrame: frame)
        let isNewRow = hovered?.content.taskID != content.taskID
        hovered = pointed
        if card?.content.taskID == content.taskID {
            card = pointed
            return
        }
        if card != nil || atEnd || isWarm {
            show(pointed)
        } else if isNewRow || opening == nil {
            opening?.cancel()
            opening = Task { [weak self] in
                try? await Task.sleep(for: SidebarHoverCardTiming.openDelay)
                guard !Task.isCancelled, let self, let hovered = self.hovered,
                      hovered.content.taskID == content.taskID else { return }
                self.show(hovered)
            }
        }
    }

    /// The pointer left a task's row.
    func rowLeft(_ taskID: UUID) {
        if suppressedTaskID == taskID { suppressedTaskID = nil }
        guard hovered?.content.taskID == taskID else { return }
        hovered = nil
        opening?.cancel()
        opening = nil
        closeSoon()
    }

    /// A row's content changed while the pointer is on it or its card is open: the card shows it now.
    func rowChanged(_ content: SidebarHoverCardContent) {
        if hovered?.content.taskID == content.taskID { hovered?.content = content }
        if card?.content.taskID == content.taskID { card?.content = content }
    }

    /// A row was laid out again where it is: the card stays beside it.
    func rowMoved(_ taskID: UUID, to frame: CGRect) {
        if hovered?.content.taskID == taskID { hovered?.rowFrame = frame }
        if card?.content.taskID == taskID { card?.rowFrame = frame }
    }

    /// The sidebar scrolled: the card closes, and the rows passing under the resting pointer open none
    /// until the pointer moves.
    func sidebarScrolled() {
        dismiss()
        closedAt = nil
        restingPointer = pointerLocation()
    }

    /// The pointer came onto the card or left it.
    func cardHovered(_ isInside: Bool) {
        isPointerInCard = isInside
        if isInside {
            closing?.cancel()
            closing = nil
        } else {
            closeSoon()
        }
    }

    /// Closes the card now: a click on its row or on its pull request, a scroll, the window going out
    /// of use. The row under the pointer opens it again only after the pointer has left it.
    func dismiss() {
        if let pointed = hovered?.content.taskID ?? card?.content.taskID { suppressedTaskID = pointed }
        opening?.cancel()
        opening = nil
        closing?.cancel()
        closing = nil
        isPointerInCard = false
        close()
    }

    private var isWarm: Bool {
        closedAt.map { clock.now - $0 < SidebarHoverCardTiming.warmInterval } ?? false
    }

    private func show(_ pointed: Card) {
        opening?.cancel()
        opening = nil
        card = pointed
    }

    private func close() {
        guard card != nil else { return }
        card = nil
        closedAt = clock.now
    }

    private func closeSoon() {
        guard card != nil, closing == nil else { return }
        closing = Task { [weak self] in
            try? await Task.sleep(for: SidebarHoverCardTiming.closeGrace)
            guard !Task.isCancelled, let self else { return }
            self.closing = nil
            if self.isPointerInCard { return }
            if let hovered = self.hovered {
                self.show(hovered)
            } else {
                self.close()
            }
        }
    }
}

private struct SidebarHoverCardStateKey: EnvironmentKey {
    static let defaultValue: SidebarHoverCardState? = nil
}

extension EnvironmentValues {
    /// The window's sidebar hover card, which task rows report the pointer to; nil where there is none.
    var sidebarHoverCard: SidebarHoverCardState? {
        get { self[SidebarHoverCardStateKey.self] }
        set { self[SidebarHoverCardStateKey.self] = newValue }
    }
}

/// Draws the open card beside its row, over the sidebar and the content: top-aligned with the row
/// (the Codex app's `side: right, align: start`) and moved up to stay in the window.
struct SidebarHoverCardLayer: View {
    let state: SidebarHoverCardState
    var onOpenPullRequest: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var cardHeight: CGFloat = 0
    @Environment(\.controlActiveState) private var windowState

    var body: some View {
        GeometryReader { container in
            if let card = state.card {
                let maxY = container.size.height - SidebarHoverCardMetrics.margin - cardHeight
                SidebarHoverCardView(content: card.content, onOpenPullRequest: { url in
                    state.dismiss()
                    onOpenPullRequest(url)
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                .onHover { state.cardHovered($0) }
                .offset(x: card.rowFrame.maxX + SidebarHoverCardMetrics.gap,
                        y: max(SidebarHoverCardMetrics.margin, min(card.rowFrame.minY, maxY)))
                .transition(.opacity)
            }
        }
        // Over nothing but the card, the layer lets the pointer through to the sidebar and the content.
        .allowsHitTesting(state.card != nil)
        // The window going out of use closes it, as the Codex app's card closes when its window blurs.
        .onChange(of: windowState) { _, now in
            if now != .key { state.dismiss() }
        }
        .onDisappear { state.dismiss() }
    }
}

/// The card: the task's title, then a line each for its project and folder, its worktree, its
/// harness, its state, a scheduled run, its processes' CPU and its pull request, which opens on a
/// click. The Codex app's card rows: a 16 pt icon column, 20 pt lines, 6 pt between icon and words.
struct SidebarHoverCardView: View {
    let content: SidebarHoverCardContent
    var onOpenPullRequest: (URL) -> Void = { _ in }
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.title)
                .font(.system(size: 13 * interfaceScale, weight: .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            line(Image(systemName: "folder")) {
                HStack(spacing: 6) {
                    Text(content.projectName ?? L10n.string("Chats"))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if content.worktree == nil {
                        Text(content.folder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let worktree = content.worktree {
                line(Image(systemName: "arrow.triangle.branch")) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.format("Worktree %@", worktree))
                            .lineLimit(1)
                        Text(content.folder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            line(HarnessIdentityIcon(harness: content.harness, size: 12 * interfaceScale)) {
                if let accountName = content.accountName {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "\(content.harness.displayName) · \(accountName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let reason = content.accountReason {
                            Text(reason)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text(content.harness.displayName)
                }
            }
            if let status = content.status {
                line(SidebarTaskStatusView(status: status.status)) {
                    Text(status.text)
                        .foregroundStyle(status.status.isProblem ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if content.isScheduledRun {
                line(Image(systemName: "clock")) { Text(L10n.string("Scheduled task")) }
            }
            if let cpuPercent = content.cpuPercent {
                line(Image(systemName: "cpu")) { Text(SidebarCPUIndicatorView.help(cpuPercent)) }
            }
            if let pullRequest = content.pullRequest {
                Button { onOpenPullRequest(pullRequest.url) } label: {
                    line(Image(systemName: pullRequest.glyph.systemName)
                        .foregroundStyle(TaskPullRequestBadgeView.color(pullRequest.tone))) {
                        Text(pullRequest.help)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarHoverCardLinkStyle())
                .parityPointer()
                .accessibilityLabel(pullRequest.openTitle)
                .accessibilityValue(pullRequest.accessibilityName)
                .accessibilityAddTraits(.isLink)
            }
        }
        .font(.system(size: 13 * interfaceScale))
        .frame(width: SidebarHoverCardMetrics.width * interfaceScale, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ParityTheme.separator)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func line<Icon: View, Words: View>(_ icon: Icon, @ViewBuilder words: () -> Words) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon
                .font(.system(size: 11 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16 * interfaceScale, height: 20 * interfaceScale)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * interfaceScale }
            words()
                .frame(minHeight: 20 * interfaceScale, alignment: .leading)
        }
    }
}

/// The pull request line: plain until the pointer is on it, then the row hover fill.
private struct SidebarHoverCardLinkStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .background(isHovered || configuration.isPressed ? ParityTheme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.horizontal, -4)
            .onHover { isHovered = $0 }
    }
}

extension SidebarTaskStatus {
    /// A state that needs the person or went wrong, whose words read in the primary colour.
    var isProblem: Bool {
        switch self {
        case .awaitingApproval, .needsInput, .waitingInBrowser, .failed, .usageLimit: true
        case .running, .reconnecting, .unread: false
        }
    }
}
