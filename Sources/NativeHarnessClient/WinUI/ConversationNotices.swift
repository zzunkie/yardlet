import Foundation
import UWP
import WinUI

/// What a provider says about the conversation itself, drawn as the Mac draws it (`ProviderNoticeViews`): that its
/// context was compacted, and the card of a plan limit that stopped the task, with what the task can do about it.
@MainActor
enum ConversationNotices {
    // MARK: - Compaction

    /// A compaction between two rules (the Mac's `CompactionMarker`): a spinner while it runs, else its mark, and the
    /// provider's words in the middle; under them a failure's reason, and the note on a compaction Yardlet ran while
    /// the task was idle. Small and quiet, orange when it failed.
    static func compaction(_ compaction: HarnessContextCompaction) -> UIElement {
        let failed = compaction.phase == .failed
        let tone: ConversationStyle.Tone = .secondary
        func words(_ text: String, centered: Bool = false) -> TextBlock {
            let block = ConversationStyle.text(text, size: ConversationStyle.captionSize, tone: tone)
            if failed { block.foreground = ConversationStyle.orange.solid.brush }
            if centered { block.textAlignment = .center }
            return block
        }
        let mark: UIElement
        if compaction.phase == .started {
            mark = ConversationStyle.spinner(size: 10)
        } else {
            mark = ConversationStyle.icon(failed ? ConversationStyle.Glyph.warning : ConversationStyle.Glyph.compact,
                                          size: 12, brush: failed ? ConversationStyle.orange.solid.brush
                                              : WindowsTheme.secondaryText.brush)
        }
        let title = words(ProviderNoticeText.compaction(compaction))
        title.textWrapping = .noWrap
        let middle = ConversationStyle.row([mark, title], spacing: 6)
        middle.verticalAlignment = .center
        middle.margin = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        let line = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto),
                      GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            line.columnDefinitions.append(column)
        }
        let leading = rule(), trailing = rule()
        try? Grid.setColumn(middle, 1)
        try? Grid.setColumn(trailing, 2)
        line.children.append(leading)
        line.children.append(middle)
        line.children.append(trailing)
        let stack = StackPanel()
        stack.spacing = 4
        stack.children.append(line)
        if failed, let message = compaction.message, !message.isEmpty { stack.children.append(words(message, centered: true)) }
        if let note = ProviderNoticeText.idleCompactionNote(compaction) { stack.children.append(words(note, centered: true)) }
        try? AutomationProperties.setName(stack, title.text)
        return stack
    }

    private static func rule() -> Border {
        let rule = Border()
        rule.height = 1
        rule.verticalAlignment = .center
        rule.background = WindowsTheme.separator.brush
        return rule
    }

    // MARK: - Plan limit

    /// A plan limit's card (the Mac's `UsageLimitCard`): its gauge and which limit stopped the task, when it resets or,
    /// once armed, when the task continues. The card the task continues from (`isLatest`) offers, while the task is
    /// idle, to continue under another account that shares its history, and before the reset to continue on its own
    /// when the limit resets, or once the reset passed, Resume. It comes with the reset its switch waits for, so its
    /// turn draws it again then and the switch gives way to Resume. Harnesses that report no such actions offer none
    /// (`AppModel.providerNotices`).
    static func limitCard(_ limit: HarnessRateLimit, entryID: UUID, isLatest: Bool, notices: TaskProviderNotices?,
                          now: Date = Date()) -> (card: UIElement, resetsAt: Date?) {
        let offersActions = isLatest && notices?.canContinue == true
        let isArmed = isLatest && UsageLimitAutoContinue.isSameReset(notices?.autoContinueResetsAt, limit.resetsAt)
        let detail: String?
        if isArmed, let resetsAt = limit.resetsAt, resetsAt > now {
            detail = L10n.format("Auto-resuming at %@", ProviderNoticeText.resetTime(resetsAt, now: now))
        } else {
            detail = ProviderNoticeText.limitReset(limit, now: now) ?? limit.message
        }
        let words = StackPanel()
        words.spacing = 5
        words.children.append(ConversationStyle.text(ProviderNoticeText.limitHeadline(limit),
                                                     size: ConversationStyle.calloutSize, semibold: true))
        if let detail, !detail.isEmpty {
            words.children.append(ConversationStyle.text(detail, size: ConversationStyle.calloutSize, tone: .secondary))
        }
        let mark = ConversationStyle.icon(ConversationStyle.Glyph.gauge, size: 15, brush: ConversationStyle.orange.solid.brush)
        mark.verticalAlignment = .top
        let head = ConversationStyle.row([mark, words], spacing: 10)
        let stack = StackPanel()
        stack.spacing = 10
        stack.children.append(head)
        var waitsForReset: Date?
        if offersActions, let notices {
            var actions: [UIElement] = []
            if let accounts = notices.accounts(), !accounts.others.isEmpty {
                actions.append(accountMenu(accounts.others, choose: notices.continueWithAccount))
            }
            if let resetsAt = limit.resetsAt, resetsAt > now {
                actions.append(autoContinueSwitch(isOn: isArmed) { notices.setAutoContinue($0, resetsAt) })
                waitsForReset = resetsAt
            } else if limit.resetsAt != nil, let resume = notices.continueAfterReset {
                actions.append(resumeButton { resume(entryID) })
            }
            if !actions.isEmpty {
                let row = ConversationStyle.row(actions, spacing: 14)
                row.margin = Thickness(left: 25, top: 0, right: 0, bottom: 0)
                stack.children.append(row)
            }
            if let error = notices.switchError, !error.isEmpty {
                let words = ConversationStyle.text(error, size: ConversationStyle.captionSize)
                words.foreground = ConversationStyle.orange.solid.brush
                words.margin = Thickness(left: 25, top: 0, right: 0, bottom: 0)
                stack.children.append(words)
            }
        }
        let frame = Border()
        frame.padding = Thickness(left: 14, top: 14, right: 14, bottom: 14)
        frame.cornerRadius = ConversationStyle.corners(11)
        frame.background = ConversationStyle.orange.opacity(0.04).brush
        frame.borderBrush = ConversationStyle.orange.opacity(0.2).brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.child = stack
        try? AutomationProperties.setName(frame, ProviderNoticeText.limitHeadline(limit))
        return (frame, waitsForReset)
    }

    /// "Continue with another account ⌄": the accounts other than the task's that share its history, by name.
    private static func accountMenu(_ accounts: [ProviderConnection],
                                    choose: @escaping @MainActor (ProviderConnection) -> Void) -> UIElement {
        let menu = MenuFlyout()
        for account in accounts {
            let item = MenuFlyoutItem()
            item.text = account.name
            item.click.addHandler { _, _ in choose(account) }
            menu.items.append(item)
        }
        let title = ConversationStyle.text(L10n.string("Continue with another account"), size: ConversationStyle.calloutSize,
                                           selectable: false, wraps: false)
        let caret = ConversationStyle.icon(ConversationStyle.Glyph.chevronDown, size: 8)
        let button = ConversationStyle.plainButton(ConversationStyle.row([title, caret], spacing: 4),
                                                   name: L10n.string("Continue with another account")) {}
        button.flyout = menu
        return button
    }

    /// "Auto-continue when limits reset", as a small switch. The switch's state is kept apart from the switch, which a
    /// handler may not hold.
    private static func autoContinueSwitch(isOn: Bool, set: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let state = SwitchState(isOn: isOn)
        let toggle = ToggleSwitch()
        toggle.isOn = isOn
        toggle.onContent = nil
        toggle.offContent = nil
        toggle.minWidth = 0
        toggle.verticalAlignment = .center
        toggle.toggled.addHandler { _, _ in
            state.isOn.toggle()
            set(state.isOn)
        }
        try? AutomationProperties.setName(toggle, L10n.string("Auto-continue when limits reset"))
        let words = ConversationStyle.text(L10n.string("Auto-continue when limits reset"),
                                           size: ConversationStyle.calloutSize, selectable: false, wraps: false)
        words.verticalAlignment = .center
        return ConversationStyle.row([words, toggle], spacing: 8)
    }

    private final class SwitchState {
        var isOn: Bool
        init(isOn: Bool) { self.isOn = isOn }
    }

    /// "Resume": the task continues where the limit stopped it, under its own account.
    private static func resumeButton(_ resume: @escaping @MainActor () -> Void) -> UIElement {
        let words = ConversationStyle.text(L10n.string("Resume"), size: ConversationStyle.calloutSize, selectable: false,
                                           wraps: false)
        words.foreground = WindowsTheme.accent.brush
        return ConversationStyle.plainButton(words, name: L10n.string("Resume"), action: resume)
    }
}
