import Foundation
import UWP
import WinUI

/// What a composer shows of the messages that wait while a turn runs, as the Mac draws it for a task of this computer
/// and of another alike: each queued message's row (`ComposerQueueRow`) above the text, the row saying the queue
/// paused, the queue-or-steer button beside Stop with its menu, and above the card the banner of a sent message being
/// edited (`ConversationEditBanner`). The task's composer and another computer's task's composer carry out the actions
/// their own way.
@MainActor
enum ComposerFollowUps {
    /// What a queued message's row offers; a nil action is not offered.
    struct RowActions {
        var moveUp: (@MainActor () -> Void)?
        var moveDown: (@MainActor () -> Void)?
        var retry: (@MainActor () -> Void)?
        var sendNow: (@MainActor () -> Void)?
        var stopAndSend: (@MainActor () -> Void)?
        var edit: (@MainActor () -> Void)?
        var remove: (@MainActor () -> Void)?
    }

    /// One queued message (`ComposerQueueRow`): what it says, shortened to the row, then where it goes and its
    /// actions, which keep their size so a long message never pushes them out of view; its menu holds them too, with
    /// the one that stops the turn for it.
    static func queueRow(title: String, failed: Bool, fromTask: Bool, chip: ComposerQueueChip,
                         actions: RowActions) -> UIElement {
        let tint = failed ? ComposerParts.red : WindowsTheme.secondaryText
        let row = Grid()
        row.minHeight = 28
        row.padding = Thickness(left: 9, top: 0, right: 4, bottom: 0)
        row.cornerRadius = ComposerParts.corners(8)
        row.background = WindowsTheme.subtleFill.brush
        row.columnSpacing = 6
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let icon = ComposerParts.glyph(fromTask && !failed ? ComposerParts.Glyph.fromTask : glyph(chip), size: 11,
                                       color: tint)
        row.children.append(icon)
        let words = ComposerParts.label(title, size: 12, color: failed ? ComposerParts.red : WindowsTheme.text, weight: 400)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        let status = ComposerParts.label(chip.status, size: 12, color: tint, weight: 400)
        try? Grid.setColumn(status, 2)
        row.children.append(status)

        let buttons = StackPanel()
        buttons.orientation = .horizontal
        buttons.spacing = 2
        func button(_ code: String, _ name: String, _ action: @escaping @MainActor () -> Void) {
            let button = ComposerParts.iconButton(code, name: name, size: 10, foreground: tint, fill: nil, radius: 6)
            button.width = 24
            button.height = 24
            button.click.addHandler { _, _ in action() }
            buttons.children.append(button)
        }
        let menu = MenuFlyout()
        func menuItem(_ title: String, _ action: @escaping @MainActor () -> Void) {
            menu.items.append(ComposerParts.menuItem(title, action: action))
        }
        if chip.canMoveUp, let moveUp = actions.moveUp {
            button(ComposerParts.Glyph.arrowUp, L10n.string("Move up"), moveUp)
            menuItem(L10n.string("Move up"), moveUp)
        }
        if chip.canMoveDown, let moveDown = actions.moveDown {
            button(ComposerParts.Glyph.arrowDown, L10n.string("Move down"), moveDown)
            menuItem(L10n.string("Move down"), moveDown)
        }
        if failed, let retry = actions.retry {
            button(ComposerParts.Glyph.retry, L10n.string("Retry"), retry)
            menuItem(L10n.string("Retry"), retry)
        } else if let send = chip.send, let sendNow = actions.sendNow {
            // In words, as the Codex app's queued message offers its Steer: the message goes now and the turn goes on.
            let control = ComposerParts.control(title: send.label, glyph: ComposerParts.Glyph.steer, tint: WindowsTheme.text)
            try? ToolTipService.setToolTip(control, send.help)
            control.click.addHandler { _, _ in sendNow() }
            buttons.children.append(control)
            menuItem(send.label, sendNow)
        }
        if let stop = chip.stopAndSend, let stopAndSend = actions.stopAndSend {
            menuItem(stop, stopAndSend)
        }
        if !fromTask, let edit = actions.edit {
            button(ComposerParts.Glyph.edit, L10n.string("Edit message"), edit)
            menuItem(L10n.string("Edit message"), edit)
        }
        if let remove = actions.remove {
            button(ComposerParts.Glyph.remove, chip.removeLabel, remove)
            menuItem(chip.removeLabel, remove)
        }
        try? Grid.setColumn(buttons, 3)
        row.children.append(buttons)
        row.contextFlyout = menu
        if let help = chip.help { try? ToolTipService.setToolTip(words, help) }
        try? AutomationProperties.setName(row, "\(L10n.string("Queue")), \(chip.status): \(title)")
        return row
    }

    private static func glyph(_ chip: ComposerQueueChip) -> String {
        switch chip.icon {
        case "checkmark.circle": ComposerParts.Glyph.delivered
        case "exclamationmark.circle": ComposerParts.Glyph.failed
        default: ComposerParts.Glyph.clock
        }
    }

    /// The row above the queue once the person stopped the turn: the queue waits until Resume.
    static func pausedRow(resume: @escaping @MainActor () -> Void) -> UIElement {
        let row = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let words = StackPanel()
        words.orientation = .horizontal
        words.spacing = 6
        words.children.append(ComposerParts.glyph(ComposerParts.Glyph.pause, size: 11))
        words.children.append(ComposerParts.label(L10n.string("Queue paused because you interrupted"), size: 12,
                                                  weight: 400))
        row.children.append(words)
        let button = ComposerParts.control(title: L10n.string("Resume"), glyph: ComposerParts.Glyph.play)
        button.click.addHandler { _, _ in resume() }
        try? Grid.setColumn(button, 1)
        row.children.append(button)
        row.margin = Thickness(left: 5, top: 0, right: 0, bottom: 0)
        return row
    }

    /// The queue-or-steer menu: Pause or Resume the queue where it is offered, then each way a message goes with its
    /// keys, the send key for `returnMode` and Ctrl+Enter for the other; steering waits until the turn can take it.
    static func menu(policy: FollowUpPolicy, returnMode: FollowUpMode, canSteer: Bool,
                     pause: (title: String, action: @MainActor () -> Void)? = nil,
                     send: @escaping @MainActor (FollowUpMode) -> Void) -> MenuFlyout {
        let menu = MenuFlyout()
        menu.placement = .top
        if let pause {
            menu.items.append(ComposerParts.menuItem(pause.title, action: pause.action))
        }
        let keys = SendShortcut.return
        menu.items.append(ComposerParts.menuItem(FollowUpPolicy.afterTurnPhrase, glyph: ComposerParts.Glyph.queue,
                                                 keys: returnMode == .queue ? keys.sendSymbol : keys.alternateSymbol) {
            send(.queue)
        })
        if let steer = policy.steerPhrase {
            let item = ComposerParts.menuItem(steer, glyph: ComposerParts.Glyph.steer,
                                              keys: returnMode == .steer ? keys.sendSymbol : keys.alternateSymbol) {
                send(.steer)
            }
            item.isEnabled = canSteer
            menu.items.append(item)
        }
        return menu
    }
}

/// The queue-or-steer button beside Stop: the queue's mark, and how many messages wait.
@MainActor
final class ComposerFollowUpButton {
    let button: Button
    private let count = TextBlock()

    init() {
        button = ComposerParts.iconButton(ComposerParts.Glyph.queue, name: L10n.string("Queue or steer"),
                                          foreground: WindowsTheme.secondaryText, fill: WindowsTheme.subtleFill,
                                          radius: ComposerParts.buttonSize / 2)
        let content = StackPanel()
        content.orientation = .horizontal
        content.spacing = 3
        content.horizontalAlignment = .center
        content.children.append(ComposerParts.glyph(ComposerParts.Glyph.queue, size: 12))
        count.fontSize = 10
        count.foreground = WindowsTheme.secondaryText.brush
        count.verticalAlignment = .center
        count.visibility = .collapsed
        content.children.append(count)
        button.content = content
        button.minWidth = ComposerParts.buttonSize
        button.width = .nan
        button.padding = Thickness(left: 6, top: 0, right: 6, bottom: 0)
        button.visibility = .collapsed
    }

    /// How many of the person's messages wait; none shows no number.
    func show(count waiting: Int) {
        count.text = waiting == 0 ? "" : "\(waiting)"
        count.visibility = waiting == 0 ? .collapsed : .visible
    }
}

/// Above the card while a sent message is being edited (the Mac's `ConversationEditBanner`): "Editing message" and
/// Cancel edit, or once the provider has taken the edit, that sending it continues the conversation.
@MainActor
final class ComposerEditBanner {
    let view = Grid()
    private var cancel = Button()
    private let taken = TextBlock()

    init(onCancel: @escaping @MainActor () -> Void) {
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            view.columnDefinitions.append(column)
        }
        view.maxWidth = WindowsTheme.contentWidth
        view.margin = Thickness(left: 39, top: 6, right: 39, bottom: 0)
        view.visibility = .collapsed
        let label = ConversationStyle.row([
            ConversationStyle.icon(ConversationStyle.Glyph.edit, size: 12),
            ConversationStyle.text(L10n.string("Editing message"), size: ConversationStyle.captionSize, selectable: false,
                                   wraps: false)
        ], spacing: 6)
        label.verticalAlignment = .center
        view.children.append(label)
        cancel = ConversationStyle.plainButton(
            ConversationStyle.text(L10n.string("Cancel edit"), size: ConversationStyle.captionSize, selectable: false,
                                   wraps: false),
            name: L10n.string("Cancel edit"), action: onCancel)
        taken.text = L10n.string("Conversation changed. Send the edited message to continue.")
        taken.fontSize = ConversationStyle.captionSize
        taken.foreground = WindowsTheme.secondaryText.brush
        taken.verticalAlignment = .center
        for trailing in [cancel as FrameworkElement, taken] {
            try? Grid.setColumn(trailing, 1)
            view.children.append(trailing)
        }
    }

    /// Shown while a message is being edited, with Cancel edit while it `canCancel`; nil hides it.
    func show(canCancel: Bool?) {
        view.visibility = canCancel == nil ? .collapsed : .visible
        cancel.visibility = canCancel == true ? .visible : .collapsed
        taken.visibility = canCancel == false ? .visible : .collapsed
    }
}
