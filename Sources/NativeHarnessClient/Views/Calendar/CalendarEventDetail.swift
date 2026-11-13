import AppKit
import SwiftUI

/// The chosen event beside the days: when and in which calendar, an invitation to answer for Google and Outlook,
/// who comes and where to join, the hand-off to an agent, and the event in its own service.
struct CalendarEventDetail: View {
    let event: CalendarEvent
    let info: CalendarInfo?
    let account: CalendarAccount?
    let color: Color
    let calendar: Calendar
    let onRespond: (CalendarResponse) async throws -> Void
    let onAskAgent: () -> Void
    let onClose: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @State private var answering: CalendarResponse?
    @State private var failure: String?

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            heading
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            if event.response != nil, account?.provider.answersInvitations == true { invitation }
            details
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            Button(L10n.string("Hand to an agent…"), action: onAskAgent)
                .buttonStyle(.bordered)
                .controlSize(.regular)
            Spacer(minLength: 0)
            openInService
        }
        .padding(20 * scale)
        .frame(width: Self.width * scale, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.separator).frame(width: 1) }
        .id(event.id)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CalendarText.title(event))
                    .font(.system(size: 18 * scale, weight: .semibold))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ParityIconButton(systemName: "xmark", help: L10n.string("Close"), action: onClose)
            }
            Text(CalendarText.when(event, calendar: calendar))
                .font(.system(size: 13 * scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let info {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(calendarLine(info))
                        .font(.system(size: 13 * scale))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func calendarLine(_ info: CalendarInfo) -> String {
        guard let account else { return info.name }
        let where_ = account.provider == .apple ? (info.source ?? account.displayName) : account.displayName
        return info.name == where_ ? info.name : info.name + " · " + where_
    }

    // MARK: - Invitation

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(answerText).font(.system(size: 13 * scale))
            HStack(spacing: 8) {
                if event.response != .accepted { answerButton(.accepted, L10n.string("Accept invitation"), prominent: event.awaitsAnswer) }
                if event.response != .declined { answerButton(.declined, L10n.string("Decline invitation"), prominent: false) }
                if answering != nil { ProgressView().controlSize(.small) }
            }
            .disabled(answering != nil)
            if let failure {
                Text(failure)
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var answerText: String {
        switch event.response {
        case .accepted: L10n.string("You accepted this invitation.")
        case .declined: L10n.string("You declined this invitation.")
        case .tentative: L10n.string("You said maybe to this invitation.")
        case .needsAction, nil: L10n.string("You haven't replied to this invitation.")
        }
    }

    @ViewBuilder
    private func answerButton(_ response: CalendarResponse, _ title: String, prominent: Bool) -> some View {
        let button = Button(title) { answer(response) }.controlSize(.regular)
        if prominent { button.parityProminentButton() } else { button.buttonStyle(.bordered) }
    }

    private func answer(_ response: CalendarResponse) {
        answering = response
        failure = nil
        Task {
            do {
                try await onRespond(response)
            } catch {
                failure = error.localizedDescription
            }
            answering = nil
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if !event.attendees.isEmpty {
                line("person.2", people)
            }
            if let url = event.conferenceURL {
                Button { OutsideBrowser.open(url) } label: {
                    line("video", CalendarText.conference(url))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(url.absoluteString)
            }
            if let location = event.location {
                line("mappin.and.ellipse", location)
            }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                line("text.alignleft", notes, limit: 6)
            }
        }
    }

    private var people: String {
        let count = event.attendees.count
        guard let organizer = event.organizer?.displayName, !organizer.isEmpty else { return L10n.format("%lld people", count) }
        return L10n.format("%lld people · organized by %@", count, organizer)
    }

    private func line(_ symbol: String, _ text: String, limit: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13 * scale))
                .lineLimit(limit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - The service

    @ViewBuilder
    private var openInService: some View {
        if let account, let (title, open) = serviceLink(account) {
            Button(action: open) {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: "arrow.up.forward").font(.system(size: 10 * scale, weight: .semibold))
                }
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .parityPointer()
        }
    }

    /// Google and Outlook open the event on their web app; the Mac's calendars open Calendar.
    private func serviceLink(_ account: CalendarAccount) -> (String, () -> Void)? {
        switch account.provider {
        case .google:
            guard let url = event.webURL else { return nil }
            return (L10n.string("Open in Google Calendar"), { OutsideBrowser.open(url) })
        case .outlook:
            guard let url = event.webURL else { return nil }
            return (L10n.string("Open in Outlook"), { OutsideBrowser.open(url) })
        case .apple:
            return (L10n.string("Open in Calendar"), {
                NSWorkspace.shared.open(URL(filePath: "/System/Applications/Calendar.app", directoryHint: .isDirectory))
            })
        }
    }
}
