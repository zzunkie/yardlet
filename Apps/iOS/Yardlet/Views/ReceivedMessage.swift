import SwiftUI
import YardletRemote

// Messages the person did not send (docs/REMOTE_PROTOCOL.md §6.2 `sender`): the Mac draws them apart from the
// person's own, and so does the phone. A `sender` kind the phone does not know draws as the person's message.

/// A message another task sent: on the left under "Sent from {task}", in a quiet outlined box, with the person's own
/// words the task passed on under it. The label opens the sending task while the Mac lists it.
struct MessageFromTask: View {
    let item: RemoteItem
    let session: HostSession

    var body: some View {
        ReceivedMessage(symbol: "bubble.left.and.bubble.right", label: label, opens: sendingTask) {
            ReceivedText(text: item.text ?? "", lines: nil)
            ForEach(Array((item.sender?.quotes ?? []).enumerated()), id: \.offset) { _, quote in
                QuotedWords(quote: quote)
            }
        }
    }

    private var label: String {
        if let name = item.sender?.name, !name.isEmpty { return String(localized: "Sent from \(name)") }
        return String(localized: "Sent from another task")
    }

    private var sendingTask: String? {
        guard let id = item.sender?.taskId, session.task(id) != nil else { return nil }
        return id
    }
}

/// A background command's or agent's notice that opened the turn: one dim line on the left, as the conversation's own
/// lines read, not the person's bubble.
struct BackgroundNotice: View {
    let item: RemoteItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "gearshape").font(.footnote).frame(width: 16).foregroundStyle(.secondary)
            Text(item.text ?? "").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Background task"))
    }
}

/// A prompt Claude Code's own schedule sent: on the left under "Scheduled check-in" or "Scheduled task: {name}",
/// clipped to two lines as the Mac clips it.
struct MessageFromSchedule: View {
    let item: RemoteItem

    var body: some View {
        ReceivedMessage(symbol: "clock", label: label, opens: nil) {
            if let text = item.text, !text.isEmpty { ReceivedText(text: text, lines: 2) }
        }
    }

    private var label: String {
        if let name = item.sender?.name, !name.isEmpty { return String(localized: "Scheduled task: \(name)") }
        return String(localized: "Scheduled check-in")
    }
}

/// Who sent a message that is not the person's, then what they sent, on the left. With a task to open, the label is a
/// link to it.
private struct ReceivedMessage<Content: View>: View {
    let symbol: String
    let label: String
    let opens: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let opens {
                    NavigationLink(value: opens) {
                        HStack(spacing: 4) {
                            sender
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the task that sent this message"))
                } else {
                    sender
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            content
        }
        .padding(.trailing, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sender: some View {
        Label {
            Text(label).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// The words of a message someone else sent, in a quiet outlined box; past `lines` they fold under "Show more".
private struct ReceivedText: View {
    let text: String
    let lines: Int?
    @State private var isExpanded = false
    /// The height the words take clipped and whole, measured at this width.
    @State private var shownHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MarkdownView.inline(text))
                .lineLimit(lines == nil || isExpanded ? nil : lines)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                .background(alignment: .top) {
                    if lines != nil {
                        Text(MarkdownView.inline(text))
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { wholeHeight = $0 }
                    }
                }
            if lines != nil, isExpanded || wholeHeight > shownHeight + 1 {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator)))
    }
}

/// The person's own words a task passed on, under its message: a quote with whose they are and when.
private struct QuotedWords: View {
    let quote: RemoteSender.Quote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Color(.separator)).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.text).font(.subheadline).textSelection(.enabled)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private var caption: String {
        guard let sentAt = quote.sentAt, let date = Self.date(sentAt) else { return String(localized: "Your message") }
        return String(localized: "Your message · \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
