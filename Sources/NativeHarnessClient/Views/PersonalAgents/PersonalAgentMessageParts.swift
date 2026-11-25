import SwiftUI

// The small parts a dot's conversation draws around its messages, in the look a task's conversation
// gives its own: the actions under a message, the line where a new day starts, the chips its files and
// links show as, quiet text buttons, and the notices above the history and the composer.

/// Under a message, as a task's message shows its actions (`SentUserMessage`, `ConversationAgentMessage`):
/// its copy, Reply where the room takes one, and when it was sent (`ConversationMessageTime`), each shown
/// while the pointer is over the message or one has keyboard focus. The row keeps its place, so showing
/// it moves nothing. The person's own message reads its time first, as a sent request's does.
struct PersonalAgentMessageActions: View {
    let copyText: String
    let sentAt: Date?
    let reply: (() -> Void)?
    var timeFirst = false
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        if !copyText.isEmpty || reply != nil || sentAt != nil {
            HStack(spacing: 12) {
                if timeFirst, let sentAt { ConversationMessageTime(date: sentAt) }
                if !copyText.isEmpty {
                    HoverRevealedAction {
                        TranscriptCopyButton(title: L10n.string("Copy message")) { copyText }
                    }
                }
                if let reply {
                    HoverRevealedAction {
                        Button(action: reply) {
                            Label(L10n.string("Reply"), systemImage: "arrowshape.turn.up.left")
                        }
                        .buttonStyle(.borderless)
                        .parityPointer()
                        .font(.yardlet(.caption, scale: scale))
                        .foregroundStyle(.secondary)
                        .help(L10n.string("Reply"))
                    }
                }
                if !timeFirst, let sentAt { ConversationMessageTime(date: sentAt) }
            }
        }
    }
}

/// Where a new day starts in the room: its name between two hairlines, "Today", "Yesterday" or its date.
struct PersonalAgentDayDivider: View {
    let date: Date
    @Environment(\.yardletInterfaceScale) private var scale

    /// The day `message` starts, when it is the first message or the one before it was sent another day.
    /// A message without a time starts none, and the one after it is weighed against the one before.
    static func startsDay(_ message: PersonalAgentMessage, after previous: PersonalAgentMessage?,
                          calendar: Calendar = .current) -> Date? {
        guard let date = message.createdAt else { return nil }
        guard let previous else { return date }
        guard let before = previous.createdAt else { return nil }
        return calendar.isDate(date, inSameDayAs: before) ? nil : date
    }

    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.string("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.string("Yesterday")
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(Self.text(for: date))
                .font(.yardlet(.caption, scale: scale).weight(.medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            rule
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(.isHeader)
    }

    private var rule: some View {
        Rectangle().fill(ParityTheme.separator).frame(height: 1).frame(maxWidth: .infinity)
    }
}

/// A file, link or way out of the room under a message: its symbol and name on a quiet chip, the hover
/// fill under the pointer. Without an action it only names the file.
struct PersonalAgentChip: View {
    let title: String
    let systemName: String
    /// A file or link the message holds, drawn on its own chip; else a quieter way out of the room.
    var isFile = false
    var alignsTrailing = false
    let action: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .parityPointer()
                .onHover { isHovering = $0 }
                .accessibilityLabel(title)
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        let shape = RoundedRectangle(cornerRadius: isFile ? ParityRadius.row : ParityRadius.control, style: .continuous)
        let hovered = isHovering && isEnabled && action != nil
        return HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11 * scale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(action == nil ? .secondary : .primary)
        }
        .font(.yardlet(.caption, scale: scale))
        .padding(.horizontal, isFile ? 10 : 8)
        .frame(minHeight: (isFile ? 28 : 24) * scale)
        .background(hovered ? ParityTheme.hoverFill : isFile ? ParityTheme.subtleFill : .clear, in: shape)
        .overlay { if isFile { shape.strokeBorder(ParityTheme.separator, lineWidth: 1) } }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.6)
        .frame(maxWidth: 360, alignment: alignsTrailing ? .trailing : .leading)
    }
}

/// A quiet text action inside a line of the conversation or its details: secondary at rest, primary
/// under the pointer, never the system's blue link.
struct PersonalAgentTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.yardlet(.caption, scale: scale).weight(.medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(minHeight: 22 * scale)
                .background(isHovering ? ParityTheme.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
    }
}

/// A fact about the room or the draft that waits on the person, over the history or the composer: a
/// symbol (or a spinner while it is under way), its words, and its actions as small buttons, on the
/// subtle fill with a hairline edge, as a task's notices stand (`TaskFolderMissingBanner`).
struct PersonalAgentNotice<Actions: View>: View {
    let text: String
    var isWorking = false
    var systemName = "exclamationmark.circle"
    @ViewBuilder var actions: () -> Actions
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.row + 2, style: .continuous)
        HStack(alignment: .center, spacing: 10) {
            Group {
                if isWorking { ProgressView().controlSize(.small) }
                else { Image(systemName: systemName).foregroundStyle(.secondary) }
            }
            .frame(width: 16 * scale)
            .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
                .fixedSize()
        }
        .font(.yardlet(.caption, scale: scale))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ParityTheme.subtleFill, in: shape)
        .overlay { shape.strokeBorder(ParityTheme.separator, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

extension PersonalAgentNotice where Actions == EmptyView {
    init(text: String, isWorking: Bool = false, systemName: String = "exclamationmark.circle") {
        self.init(text: text, isWorking: isWorking, systemName: systemName) { EmptyView() }
    }
}
