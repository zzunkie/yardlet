import SwiftUI

// A message's actions as the Claude desktop app's Code screen shows them (`MessageActions[data-reveal]`):
// out of sight until the pointer is over the message, and shown while one of them has keyboard focus.
// An action out of sight is out of the accessibility tree too, so the message that holds one also
// offers it as its own accessibility action (`accessibilityActions`).

private struct HoverRevealsActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The pointer is over the message whose actions `HoverRevealedAction` shows.
    fileprivate(set) var hoverRevealsActions: Bool {
        get { self[HoverRevealsActionsKey.self] }
        set { self[HoverRevealsActionsKey.self] = newValue }
    }
}

/// Tracks the pointer over a message for the actions inside it. Only the actions read it, so moving
/// the pointer redraws them and not the message.
struct RevealsActionsOnHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .environment(\.hoverRevealsActions, isHovering)
            .pointerHover { isHovering = $0 }
    }
}

/// An action shown while the pointer is over its message (`RevealsActionsOnHover`), while it has
/// keyboard focus, or always in a window-less render that asks for it
/// (`revealsSentMessageActions`). It keeps its place, so showing it moves nothing.
struct HoverRevealedAction<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.hoverRevealsActions) private var isHovering
    @Environment(\.revealsSentMessageActions) private var revealsActions
    @FocusState private var hasFocus: Bool

    var body: some View {
        content
            .focused($hasFocus)
            .opacity(isShown ? 1 : 0)
    }

    private var isShown: Bool {
#if DEBUG
        if HoverRevealedActionsCapture.hidesActions { return false }
#endif
        return revealsActions || isHovering || hasFocus
    }
}

/// A control a message draws beside its copy for what its turn offers to do with it
/// (`ConversationTurnAction`): the person's request its edit and the restore of its files, the turn's
/// answer its fork.
struct ConversationMessageAction: Identifiable {
    let id: ConversationTurnAction
    let title: String
    let systemImage: String
    let perform: @MainActor () -> Void
    /// What the action copies, when copying is what it does: it is drawn as a message's copy is, with
    /// its "Copied" feedback.
    var copies: (@MainActor () -> String?)? = nil
}

private struct ConversationMessageActionsKey: EnvironmentKey {
    static let defaultValue: [ConversationMessageAction] = []
}

extension EnvironmentValues {
    /// What the message drawn here offers beside its copy; the turn sets it on its request and its
    /// answer only.
    var conversationMessageActions: [ConversationMessageAction] {
        get { self[ConversationMessageActionsKey.self] }
        set { self[ConversationMessageActionsKey.self] = newValue }
    }
}

/// A message's actions after its copy, each shown as `HoverRevealedAction` shows one, in the copy's
/// look.
struct ConversationMessageActionButtons: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let actions: [ConversationMessageAction]

    var body: some View {
        ForEach(actions) { action in
            HoverRevealedAction {
                if let copies = action.copies {
                    TranscriptCopyButton(title: action.title, payload: copies)
                } else {
                    button(action)
                }
            }
        }
    }

    private func button(_ action: ConversationMessageAction) -> some View {
        Button(action: action.perform) {
            Label(action.title, systemImage: action.systemImage)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .font(.yardlet(.caption, scale: interfaceScale))
        .foregroundStyle(.secondary)
        .help(action.title)
    }
}

/// When a message was sent or written, beside its actions and shown with them: the time alone for
/// today's, its day too for an earlier one, and its year for one of an earlier year. Its whole date
/// is in its tooltip. A message no record names a time for (`ConversationItem.recordedAt`) shows none.
///
/// The time is worded only while it shows, so the many messages out of reach of the pointer format
/// nothing, and it reads the day as it is when shown, past midnight too. Until then a blank keeps the
/// row's height.
struct ConversationMessageTime: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.hoverRevealsActions) private var isHovering
    @Environment(\.revealsSentMessageActions) private var revealsActions
    let date: Date

    var body: some View {
        HoverRevealedAction {
            Group {
                if revealsActions || isHovering {
                    Text(Self.text(for: date))
                        .help(date.formatted(date: .complete, time: .shortened))
                        .accessibilityLabel(date.formatted(date: .complete, time: .shortened))
                } else {
                    Text(verbatim: " ")
                        .accessibilityHidden(true)
                }
            }
            .font(.yardlet(.caption, scale: interfaceScale))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute()
        if !calendar.isDate(date, inSameDayAs: now) {
            style = style.month(.abbreviated).day()
            if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
                style = style.year()
            }
        }
        return date.formatted(style)
    }
}

#if DEBUG
/// A script capturing the showcase (`--ui-fixture-ignore-pointer`) shows no message's actions and no
/// sidebar row's hover or hover card: whether one shows would depend on where the person's pointer
/// and the window's focus happen to be, and a row moving under a resting pointer counts as hovered.
@MainActor
enum HoverRevealedActionsCapture {
    static var hidesActions = false
}
#endif
