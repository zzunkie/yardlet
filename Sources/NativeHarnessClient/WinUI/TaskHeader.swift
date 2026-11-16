import Foundation
import UWP
import WinUI

/// The header above a task's conversation, as the Mac's (`TaskHeaderIdentity`): the task's title, which opens its
/// actions (`TaskActions.titleMenu`: the account, Rename task, Pin, Archive, Show in File Explorer), its harness's mark
/// and name, and while it works a progress ring, or the Mac's mark for a request waiting or a failed turn. The Mac's
/// panel buttons at its right are the Mac's alone.
@MainActor
final class TaskHeader {
    let view = Grid()
    private let actions: TaskActions
    private let title = DropDownButton()
    private let titleText = TextBlock()
    private let harnessMark = Border()
    private let harnessName = TextBlock()
    private let activity = Grid()
    private var drawn: State?

    private struct State: Equatable {
        let id: UUID
        let title: String
        let harness: HarnessKind
        let status: SessionStatus
    }

    init(actions: TaskActions) {
        self.actions = actions
        view.height = 44
        view.padding = Thickness(left: 12, top: 4, right: 16, bottom: 0)
        SidebarStyle.columns(view, [SidebarStyle.auto, SidebarStyle.auto, SidebarStyle.auto, SidebarStyle.star])
        view.columnSpacing = 8

        titleText.fontSize = 13
        titleText.fontWeight = UWP.FontWeight(weight: 500)
        titleText.foreground = WindowsTheme.text.brush
        titleText.textWrapping = .noWrap
        titleText.textTrimming = .characterEllipsis
        titleText.maxLines = 1
        title.content = titleText
        SidebarStyle.stylePlain(title)
        title.horizontalAlignment = .left
        title.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        title.padding = Thickness(left: 8, top: 4, right: 6, bottom: 4)
        title.maxWidth = 480
        title.verticalAlignment = .center
        view.children.append(title)

        let harness = StackPanel()
        harness.orientation = .horizontal
        harness.spacing = 6
        harness.verticalAlignment = .center
        harnessMark.width = 14
        harnessMark.height = 14
        harness.children.append(harnessMark)
        harnessName.fontSize = 12
        harnessName.foreground = WindowsTheme.secondaryText.brush
        harnessName.verticalAlignment = .center
        harness.children.append(harnessName)
        try? Grid.setColumn(harness, 1)
        view.children.append(harness)

        activity.width = 16
        activity.height = 16
        activity.verticalAlignment = .center
        try? Grid.setColumn(activity, 2)
        view.children.append(activity)
        view.visibility = .collapsed
    }

    /// Shows `session`'s header, or none; only what changed is drawn again, since the conversation calls this as it
    /// streams.
    func show(_ session: SessionRecord?) {
        let state = session.map { State(id: $0.id, title: $0.title, harness: $0.harness, status: $0.status) }
        guard state != drawn else { return }
        let before = drawn
        drawn = state
        guard let state else {
            view.visibility = .collapsed
            return
        }
        view.visibility = .visible
        if before?.id != state.id { title.flyout = actions.titleMenu(for: state.id) }
        if before?.title != state.title {
            titleText.text = state.title
            try? AutomationProperties.setName(title, state.title)
            try? ToolTipService.setToolTip(title, state.title)
        }
        if before?.harness != state.harness {
            harnessMark.child = HarnessIcon.element(for: state.harness, size: 14)
            harnessName.text = state.harness.displayName
        }
        if before?.status != state.status { showActivity(state.status) }
    }

    /// Running, waiting for approval, or failed, beside the harness, as the Mac's `TaskHeaderActivity`.
    private func showActivity(_ status: SessionStatus) {
        activity.children.clear()
        let mark: FrameworkElement
        switch status {
        case .running:
            let ring = ProgressRing()
            ring.isActive = true
            ring.width = 14
            ring.height = 14
            mark = ring
        case .waitingForApproval:
            mark = SidebarStyle.glyph("\u{EA18}", size: 12, color: SidebarStyle.orange)
        case .failed:
            mark = SidebarStyle.glyph("\u{E783}", size: 12, color: SidebarStyle.red)
        case .ready, .completed:
            return
        }
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .center
        try? AutomationProperties.setName(mark, status.displayName)
        try? ToolTipService.setToolTip(mark, status.displayName)
        activity.children.append(mark)
    }
}
