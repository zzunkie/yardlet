import Foundation
import YardletAgentTools

/// What Claude Code's request card says for an Apple service's write: a TestFlight tester invited or
/// removed, a build given to a group, a review answered, or a version submitted for App Review; an
/// event created, changed, or deleted in the Mac's calendars; a reminder added or marked done.
enum AppleToolApproval {
    static func request(_ service: LocalConnectorService, tool: String, account: String?,
                        input: JSONValue) -> (title: String, detail: String)? {
        switch service {
        case .appStoreConnect: appStoreConnect(tool, key: account, input: input)
        case .appleCalendar: calendar(tool, input: input)
        case .appleReminders: reminders(tool, input: input)
        default: nil
        }
    }

    private static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func preview(_ text: String, limit: Int = 1_200) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func appStoreConnect(_ tool: String, key: String?, input: JSONValue) -> (title: String, detail: String)? {
        typealias Catalog = AppStoreConnectToolCatalog
        var lines: [String] = []
        if let group = text(input, "groupId") { lines.append(L10n.format("Group %@", group)) }
        let title: String
        switch tool {
        case Catalog.addBetaTester:
            if let email = text(input, "email") {
                let name = [text(input, "firstName"), text(input, "lastName")].compactMap { $0 }.joined(separator: " ")
                lines.append(L10n.format("Invites: %@", name.isEmpty ? email : "\(name) <\(email)>"))
                lines.append(L10n.string("Apple emails the invitation."))
            } else if let tester = text(input, "testerId") {
                lines.append(L10n.format("Tester %@", tester))
            }
            title = L10n.string("Allow Claude to add a TestFlight tester?")
        case Catalog.removeBetaTester:
            if let tester = text(input, "testerId") { lines.append(L10n.format("Tester %@", tester)) }
            title = L10n.string("Allow Claude to remove a TestFlight tester from a group?")
        case Catalog.addBuildToGroup:
            if let build = text(input, "buildId") { lines.append(L10n.format("Build %@", build)) }
            lines.append(L10n.string("The group's testers can install it."))
            title = L10n.string("Allow Claude to give a build to a TestFlight group?")
        case Catalog.replyToReview:
            if let review = text(input, "reviewId") { lines.append(L10n.format("Review %@", review)) }
            lines.append(L10n.string("It shows on the App Store, in place of an earlier response."))
            if let body = text(input, "responseBody") { lines.append("\n" + preview(body)) }
            title = L10n.string("Allow Claude to publish a response to an App Store review?")
        case Catalog.submitForReview:
            if let version = text(input, "versionId") { lines.append(L10n.format("Version %@", version)) }
            title = L10n.string("Allow Claude to submit an App Store version for App Review?")
        default:
            return nil
        }
        if let key { lines.append(L10n.format("App Store Connect key %@", key)) }
        return (title, lines.joined(separator: "\n"))
    }

    private static func calendar(_ tool: String, input: JSONValue) -> (title: String, detail: String)? {
        var lines: [String] = []
        if let event = text(input, "eventId"), tool != MacCalendarToolCatalog.createEvent { lines.append(L10n.format("Event %@", event)) }
        if let summary = text(input, "summary") { lines.append(L10n.format("Title: %@", summary)) }
        let start = text(input, "startTime"), end = text(input, "endTime")
        if let start {
            lines.append(L10n.format("When: %@", end.map { "\(start) – \($0)" } ?? start))
        } else if let end {
            lines.append(L10n.format("Ends: %@", end))
        }
        if let zone = text(input, "timeZone") { lines.append(L10n.format("Time zone: %@", zone)) }
        if let location = text(input, "location") { lines.append(L10n.format("Location: %@", location)) }
        if text(input, "span") == "futureEvents" { lines.append(L10n.string("This event and those after it.")) }
        let title: String
        switch tool {
        case MacCalendarToolCatalog.createEvent: title = L10n.string("Allow Claude to create an event in this Mac's calendars?")
        case MacCalendarToolCatalog.updateEvent: title = L10n.string("Allow Claude to change an event in this Mac's calendars?")
        case MacCalendarToolCatalog.deleteEvent: title = L10n.string("Allow Claude to delete an event from this Mac's calendars?")
        default: return nil
        }
        var detail = lines.joined(separator: "\n")
        if let notes = text(input, "description") { detail += (detail.isEmpty ? "" : "\n\n") + preview(notes, limit: 600) }
        return (title, detail)
    }

    private static func reminders(_ tool: String, input: JSONValue) -> (title: String, detail: String)? {
        switch tool {
        case MacRemindersToolCatalog.createReminder:
            var lines: [String] = []
            if let title = text(input, "title") { lines.append(L10n.format("Title: %@", title)) }
            if let due = text(input, "dueDate") { lines.append(L10n.format("Due: %@", due)) }
            if let notes = text(input, "notes") { lines.append("\n" + preview(notes, limit: 600)) }
            return (L10n.string("Allow Claude to add a reminder on this Mac?"), lines.joined(separator: "\n"))
        case MacRemindersToolCatalog.completeReminder:
            let undo = input["completed"]?.boolValue == false
            return (undo ? L10n.string("Allow Claude to mark a reminder not done?") : L10n.string("Allow Claude to mark a reminder done?"),
                    text(input, "reminderId").map { L10n.format("Reminder %@", $0) } ?? "")
        default:
            return nil
        }
    }
}
