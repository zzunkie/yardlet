import Foundation
import YardletAgentTools

/// Yardlet's own Outlook mail server: the tools it offers each signed-in Microsoft account, over
/// Microsoft Graph's mail API (learn.microsoft.com/graph/api/resources/mail-api-overview). Names
/// and arguments follow Yardlet's Gmail tools where the two mean the same (`get_message`,
/// `create_draft`, `send_draft`, `send_message`), so a model uses both mailboxes alike. Each
/// reaches a harness under the account's slug (`outlook_search_messages`).
///
/// Two delegated permissions, neither needing an administrator's consent: `Mail.ReadWrite` (read,
/// draft, mark, flag, move) and `Mail.Send`. Sending and changing a message ask the person before
/// every call through the harness's own approval (`approvalRequired`). There is no delete.
enum OutlookMailToolCatalog {
    static let searchMessages = "search_messages"
    static let getMessage = "get_message"
    static let listFolders = "list_folders"
    static let createDraft = "create_draft"
    static let sendDraft = "send_draft"
    static let sendMessage = "send_message"
    static let updateMessage = "update_message"

    static let scopes = ["Mail.ReadWrite", "Mail.Send"]

    static let approvalRequired: Set<String> = [sendDraft, sendMessage, updateMessage]

    static let flags = ["flagged", "complete", "notFlagged"]

    private typealias Schema = ConnectorToolSchema

    private static let outgoing: [String: ToolJSON] = [
        "to": Schema.stringArray("Recipient addresses."),
        "cc": Schema.stringArray("Cc addresses."),
        "bcc": Schema.stringArray("Bcc addresses."),
        "subject": Schema.string("Subject. A reply keeps the original's when left out."),
        "body": Schema.string("Plain-text body."),
        "htmlBody": Schema.string("HTML body, in place of body."),
        "replyToMessageId": Schema.string("The message this replies to; the reply stays in its conversation."),
        "replyAll": Schema.boolean("With replyToMessageId, reply to everyone on the original. Defaults to false."),
        "attachments": Schema.stringArray(GmailAttachmentFiles.argumentDescription + " At most 3 MB each.")
    ]

    static let tools: [ToolJSON] = [
        Schema.tool(searchMessages, "Search messages",
                    "Searches the mailbox, newest first, with Outlook search words (from:ana subject:invoice, "
                        + "received>=2026-10-01, hasattachments:yes) or none. Gives the sender, recipients, subject, date, "
                        + "preview, and flags; no body.",
                    properties: [
                        "query": Schema.string("Outlook search (KQL) or plain words. Without one, the newest messages."),
                        "folderId": Schema.string("A folder ID from list_folders, or inbox, sentitems, drafts, archive, "
                            + "deleteditems, junkemail. Defaults to every folder."),
                        "unreadOnly": Schema.boolean("Only unread messages."),
                        "pageSize": Schema.integer("Messages per page, 1 to 50. Defaults to 20.", 1...50),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], readOnly: true),
        Schema.tool(getMessage, "Get message",
                    "Reads one message: headers, body as text (or HTML), and its attachments' names and sizes.",
                    properties: [
                        "messageId": Schema.string("The message's ID."),
                        "format": Schema.enumeration("text (default) or html.", ["text", "html"])
                    ], required: ["messageId"], readOnly: true),
        Schema.tool(listFolders, "List folders",
                    "Lists the mailbox's top folders with their IDs and unread and total counts.",
                    properties: [
                        "parentFolderId": Schema.string("A folder whose subfolders to list instead."),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], readOnly: true),
        Schema.tool(createDraft, "Create draft",
                    "Saves a draft in Drafts without sending it. A reply draft stays in the original's conversation.",
                    properties: outgoing, readOnly: false, openWorld: true),
        Schema.tool(sendDraft, "Send draft", "Sends a draft saved earlier.",
                    properties: ["draftId": Schema.string("The draft's ID, from create_draft.")],
                    required: ["draftId"], readOnly: false, openWorld: true),
        Schema.tool(sendMessage, "Send message",
                    "Sends a message now and keeps it in Sent Items. A reply goes to the original's sender (or everyone "
                        + "with replyAll) in its conversation.",
                    properties: outgoing, readOnly: false, openWorld: true),
        Schema.tool(updateMessage, "Update message",
                    "Marks a message read or unread, flags it, sets its categories, or moves it to a folder (archive "
                        + "with moveToFolderId archive). Moving gives the message a new ID.",
                    properties: [
                        "messageId": Schema.string("The message's ID."),
                        "isRead": Schema.boolean("Read (true) or unread (false)."),
                        "flag": Schema.enumeration("flagged, complete, or notFlagged.", flags),
                        "categories": Schema.stringArray("The categories it should have, replacing the ones it has."),
                        "moveToFolderId": Schema.string("A folder ID from list_folders, or archive, inbox, deleteditems, junkemail.")
                    ], required: ["messageId"], readOnly: false, destructive: true, openWorld: true)
    ]
}
