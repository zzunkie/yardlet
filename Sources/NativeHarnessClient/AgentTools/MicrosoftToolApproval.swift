import Foundation
import YardletAgentTools

/// What Claude Code's request card says for a Microsoft tool that writes: an Outlook send or a
/// message changed, an Outlook event created, changed, deleted, or answered, a OneDrive file or
/// folder created, or a Teams message sent. It names the account and what the call would do, as
/// the Gmail and Google cards do (`GmailToolApproval`, `GoogleToolApproval`); a draft to send shows
/// what it holds, read from Outlook first. Claude Code asks before each such call; the card offers
/// no "always allow".
enum MicrosoftToolApproval {
    static func request(_ service: LocalConnectorService, tool: String, account: String?,
                        input: JSONValue, draft: MailDraftPreview? = nil) -> (title: String, detail: String)? {
        let account = account ?? service.name
        switch service {
        case .outlookMail: return mail(tool, account: account, input: input, draft: draft)
        case .outlookCalendar: return calendar(tool, account: account, input: input)
        case .oneDrive: return drive(tool, account: account, input: input)
        case .teams: return teams(tool, account: account, input: input)
        default: return nil
        }
    }

    private static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func list(_ input: JSONValue, _ key: String) -> [String] {
        switch input[key] {
        case .array(let values)?: values.compactMap(\.stringValue)
        case .string(let value)?: [value]
        default: []
        }
    }

    private static func preview(_ text: String, limit: Int = 1_200) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func joined(_ lines: [String], body: String?) -> String {
        var detail = lines.joined(separator: "\n")
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            detail += (detail.isEmpty ? "" : "\n\n") + preview(body)
        }
        return detail
    }

    private static func mail(_ tool: String, account: String, input: JSONValue,
                             draft: MailDraftPreview?) -> (title: String, detail: String)? {
        var lines: [String] = []
        switch tool {
        case OutlookMailToolCatalog.sendMessage:
            let to = list(input, "to"), cc = list(input, "cc"), bcc = list(input, "bcc")
            if !to.isEmpty { lines.append(L10n.format("To: %@", to.joined(separator: ", "))) }
            if !cc.isEmpty { lines.append(L10n.format("Cc: %@", cc.joined(separator: ", "))) }
            if !bcc.isEmpty { lines.append(L10n.format("Bcc: %@", bcc.joined(separator: ", "))) }
            if let subject = text(input, "subject") { lines.append(L10n.format("Subject: %@", subject)) }
            if text(input, "replyToMessageId") != nil {
                lines.append(input["replyAll"] == .bool(true) ? L10n.string("Replies to everyone on the message.")
                             : L10n.string("Replies in the message's thread."))
            }
            lines += GmailToolApproval.attachmentLines(GmailAttachmentFiles.describe(list(input, "attachments")))
            let body = text(input, "body") ?? text(input, "htmlBody").map(GmailText.plainText(fromHTML:))
            return (L10n.format("Allow Claude to send an email from %@?", account), joined(lines, body: body))
        case OutlookMailToolCatalog.sendDraft:
            return (L10n.format("Allow Claude to send a draft from %@?", account),
                    draft.map(GmailToolApproval.draftDetail) ?? text(input, "draftId").map { L10n.format("Draft %@", $0) } ?? "")
        case OutlookMailToolCatalog.updateMessage:
            if let message = text(input, "messageId") { lines.append(L10n.format("Message %@", message)) }
            switch input["isRead"] {
            case .bool(true)?: lines.append(L10n.string("Marks it read."))
            case .bool(false)?: lines.append(L10n.string("Marks it unread."))
            default: break
            }
            if let flag = text(input, "flag") { lines.append(L10n.format("Flag: %@", flag)) }
            if input["categories"] != nil {
                let categories = list(input, "categories")
                lines.append(categories.isEmpty ? L10n.string("Clears its categories.")
                             : L10n.format("Categories: %@", categories.joined(separator: ", ")))
            }
            if let folder = text(input, "moveToFolderId") { lines.append(L10n.format("Moves it to %@.", folder)) }
            return (L10n.format("Allow Claude to change a message in %@?", account), lines.joined(separator: "\n"))
        default:
            return nil
        }
    }

    private static func calendar(_ tool: String, account: String, input: JSONValue) -> (title: String, detail: String)? {
        var lines: [String] = []
        if let event = text(input, "eventId") { lines.append(L10n.format("Event %@", event)) }
        if let summary = text(input, "summary") { lines.append(L10n.format("Title: %@", summary)) }
        let start = text(input, "startTime"), end = text(input, "endTime")
        if let start {
            lines.append(L10n.format("When: %@", end.map { "\(start) – \($0)" } ?? start))
        } else if let end {
            lines.append(L10n.format("Ends: %@", end))
        }
        if let zone = text(input, "timeZone") { lines.append(L10n.format("Time zone: %@", zone)) }
        let invited = list(input, "attendeeEmails") + list(input, "optionalAttendeeEmails") + list(input, "addedAttendeeEmails")
        if !invited.isEmpty { lines.append(L10n.format("Invites: %@", invited.joined(separator: ", "))) }
        let removed = list(input, "removedAttendeeEmails")
        if !removed.isEmpty { lines.append(L10n.format("Removes: %@", removed.joined(separator: ", "))) }
        if input["addTeamsMeeting"] == .bool(true) { lines.append(L10n.string("Adds a Teams meeting link.")) }
        if let location = text(input, "location") { lines.append(L10n.format("Location: %@", location)) }
        let title: String
        switch tool {
        case OutlookCalendarToolCatalog.createEvent:
            if !invited.isEmpty { lines.append(L10n.string("Outlook sends the attendees an invitation.")) }
            title = L10n.format("Allow Claude to create an event in %@'s calendar?", account)
        case OutlookCalendarToolCatalog.updateEvent:
            lines.append(L10n.string("Outlook sends the attendees an update."))
            title = L10n.format("Allow Claude to change an event in %@'s calendar?", account)
        case OutlookCalendarToolCatalog.deleteEvent:
            lines.append(L10n.string("For a meeting the account organizes, Outlook sends the attendees a cancellation."))
            title = L10n.format("Allow Claude to delete an event from %@'s calendar?", account)
        case OutlookCalendarToolCatalog.respondToEvent:
            let answer = switch text(input, "responseStatus") {
            case "accepted"?: L10n.string("Going")
            case "declined"?: L10n.string("Not going")
            default: L10n.string("Maybe")
            }
            lines.append(L10n.format("Answer: %@", answer))
            if let comment = text(input, "responseComment") { lines.append(L10n.format("Note: %@", comment)) }
            title = L10n.format("Allow Claude to answer an invitation as %@?", account)
        default:
            return nil
        }
        return (title, joined(lines, body: text(input, "description")))
    }

    private static func drive(_ tool: String, account: String, input: JSONValue) -> (title: String, detail: String)? {
        var lines: [String] = []
        if let name = text(input, "name") { lines.append(L10n.format("Name: %@", name)) }
        if let folder = text(input, "folderId") ?? text(input, "parentFolderId") { lines.append(L10n.format("Folder %@", folder)) }
        if let type = text(input, "mimeType") { lines.append(L10n.format("Type: %@", type)) }
        lines.append(text(input, "conflictBehavior") == "rename" ? L10n.string("With that name taken, it gets a new name.")
                     : L10n.string("With that name taken, nothing changes."))
        switch tool {
        case OneDriveToolCatalog.uploadFile:
            var detail = joined(lines, body: input["content"]?.stringValue)
            if text(input, "contentBase64") != nil { detail += "\n" + L10n.string("With content other than text.") }
            return (L10n.format("Allow Claude to create a file in %@'s OneDrive?", account), detail)
        case OneDriveToolCatalog.createFolder:
            return (L10n.format("Allow Claude to create a folder in %@'s OneDrive?", account), lines.joined(separator: "\n"))
        default:
            return nil
        }
    }

    private static func teams(_ tool: String, account: String, input: JSONValue) -> (title: String, detail: String)? {
        var lines: [String] = []
        switch tool {
        case TeamsToolCatalog.sendChatMessage:
            if let chat = text(input, "chatId") { lines.append(L10n.format("Chat %@", chat)) }
        case TeamsToolCatalog.sendChannelMessage:
            if let team = text(input, "teamId"), let channel = text(input, "channelId") {
                lines.append(L10n.format("Team %@ · channel %@", team, channel))
            }
            if let subject = text(input, "subject") { lines.append(L10n.format("Subject: %@", subject)) }
            if text(input, "replyToMessageId") != nil { lines.append(L10n.string("Replies in the post's thread.")) }
        default:
            return nil
        }
        return (L10n.format("Allow Claude to send a Teams message as %@?", account), joined(lines, body: text(input, "content")))
    }
}
