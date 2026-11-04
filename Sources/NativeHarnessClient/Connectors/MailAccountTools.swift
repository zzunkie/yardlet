import Foundation
import YardletAgentTools

/// The tools a mail account added with a password (`LocalConnectorService.imapMail`) offers agents,
/// over the mailbox's own transport for it (`MailAccountTransport`). Names and arguments follow
/// Yardlet's Outlook mail tools where the two mean the same, so a model uses every mailbox alike. Each
/// reaches a harness under the account's slug (`mail_search_messages`). Sending asks the person before
/// every call through the harness's own approval (`approvalRequired`); there is no delete.
enum MailAccountToolCatalog {
    static let searchMessages = "search_messages"
    static let getMessage = "get_message"
    static let listFolders = "list_folders"
    static let createDraft = "create_draft"
    static let sendDraft = "send_draft"

    static let approvalRequired: Set<String> = [sendDraft]

    private typealias Schema = ConnectorToolSchema

    static let tools: [ToolJSON] = [
        Schema.tool(searchMessages, "Search messages",
                    "Lists a folder's newest messages, or those the mail server's search finds for the words given. "
                        + "Gives each message's ID, sender, recipients, subject, date, first words and flags; no body.",
                    properties: [
                        "query": Schema.string("Words to search for in the messages. Without them, the newest messages."),
                        "folderId": Schema.string("A folder ID from list_folders. Defaults to the inbox."),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], readOnly: true),
        Schema.tool(getMessage, "Get message",
                    "Reads one message: headers, body as text, and its attachments' names and sizes.",
                    properties: ["messageId": Schema.string("The message's ID, from search_messages.")],
                    required: ["messageId"], readOnly: true),
        Schema.tool(listFolders, "List folders",
                    "Lists the account's folders with their IDs, what each is for (inbox, sent, drafts, archive, spam, "
                        + "trash) and unread counts where the server gives them.",
                    properties: [:], readOnly: true),
        Schema.tool(createDraft, "Create draft",
                    "Saves a draft in the account's Drafts without sending it. A reply is addressed to the original's "
                        + "sender (or everyone with replyAll) and carries its subject and quote.",
                    properties: [
                        "to": Schema.stringArray("Recipient addresses."),
                        "cc": Schema.stringArray("Cc addresses."),
                        "bcc": Schema.stringArray("Bcc addresses."),
                        "subject": Schema.string("Subject. A reply takes the original's when left out."),
                        "body": Schema.string("Plain-text body. A reply's quote of the original follows it."),
                        "replyToMessageId": Schema.string("The message this replies to."),
                        "replyAll": Schema.boolean("With replyToMessageId, reply to everyone on the original. Defaults to false."),
                        "attachments": Schema.stringArray(GmailAttachmentFiles.argumentDescription)
                    ], readOnly: false, openWorld: true),
        Schema.tool(sendDraft, "Send draft", "Sends a draft saved earlier and keeps a copy in Sent.",
                    properties: ["draftId": Schema.string("The draft's ID, from create_draft.")],
                    required: ["draftId"], readOnly: false, openWorld: true)
    ]
}

/// Runs one mail account tool call through the account's transport and answers with compact JSON text.
/// Arguments are checked first; a mistake the model can fix is an error result, and the server's own
/// failures (`MailFailure`) are the caller's to report. A message read here is not marked read.
struct MailAccountToolRunner {
    let transport: any MailAccountTransport
    let account: MailAccount
    /// The calling task's folders, where attachments may come from besides the person's own
    /// (`GmailAttachmentFiles`).
    var taskFolders: [URL] = []

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = MailAccountToolCatalog

    /// A body is cut here, as Gmail's and Outlook's are.
    static let bodyLimit = 40_000

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.searchMessages: result = try await search(arguments)
            case Catalog.getMessage: result = try await message(arguments)
            case Catalog.listFolders: result = try await folders()
            case Catalog.createDraft: result = try await draft(arguments)
            case Catalog.sendDraft: result = try await send(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch let problem as GmailOutgoingMessage.Problem {
            return .error(problem.localizedDescription)
        }
    }

    private func search(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let token = Arguments.string(arguments, "pageToken")
        let page: MailPage
        if let query = Arguments.string(arguments, "query") {
            page = try await transport.search(query, pageToken: token)
        } else if let folderID = Arguments.string(arguments, "folderId") {
            guard let folder = try await transport.folders().first(where: { $0.id == folderID }) else {
                throw Problem.invalid("folderId is not a folder of this account; list_folders gives their IDs.")
            }
            page = try await transport.list(folder, pageToken: token)
        } else {
            page = try await transport.inbox(pageToken: token)
        }
        var answer: [String: ToolJSON] = ["messages": .array(page.threads.map(Self.line))]
        if let next = page.nextPageToken { answer["nextPageToken"] = .string(next) }
        return .object(answer)
    }

    private func message(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "messageId")
        let thread = try await transport.thread(id)
        return .object(["messages": .array(thread.messages.map { message in
            var fields: [String: ToolJSON] = [
                "id": .string(message.id),
                "from": .string(MailComposition.formatted(message.from)),
                "to": .array(message.to.map { .string(MailComposition.formatted($0)) }),
                "date": .string(ISO8601DateFormatter().string(from: message.date)),
                "subject": .string(message.subject),
                "body": .string(message.text.count > Self.bodyLimit
                                ? String(message.text.prefix(Self.bodyLimit)) + "\n[cut at \(Self.bodyLimit) characters]"
                                : message.text),
                "unread": .bool(message.isUnread),
                "draft": .bool(message.isDraft)
            ]
            if !message.cc.isEmpty { fields["cc"] = .array(message.cc.map { .string(MailComposition.formatted($0)) }) }
            if !message.attachments.isEmpty {
                fields["attachments"] = .array(message.attachments.map {
                    .object(["name": .string($0.name), "size": .integer(Int64($0.size)), "mimeType": .string($0.mimeType)])
                })
            }
            return .object(fields)
        })])
    }

    private func folders() async throws -> ToolJSON {
        .object(["folders": .array(try await transport.folders().map { folder in
            var fields: [String: ToolJSON] = ["id": .string(folder.id), "name": .string(folder.name),
                                              "role": .string(Self.role(folder.role))]
            if let unread = folder.unreadCount { fields["unread"] = .integer(Int64(unread)) }
            return .object(fields)
        })])
    }

    private func draft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let to = try Arguments.strings(arguments, "to"), cc = try Arguments.strings(arguments, "cc")
        let bcc = try Arguments.strings(arguments, "bcc")
        let body = Arguments.string(arguments, "body") ?? ""
        let files = try GmailAttachmentFiles.check(try Arguments.strings(arguments, "attachments"),
                                                   roots: GmailAttachmentFiles.roots(taskFolders: taskFolders))
        var composition: MailComposition
        if let replyTo = Arguments.string(arguments, "replyToMessageId") {
            let thread = try await transport.thread(replyTo)
            guard let original = thread.messages.last(where: { !$0.isDraft }) else {
                throw Problem.invalid("replyToMessageId has no message to reply to.")
            }
            composition = .answering(original, in: thread, as: Arguments.bool(arguments["replyAll"]) == true ? .replyAll : .reply,
                                     from: account)
            composition.body = body + composition.body
            if !to.isEmpty { composition.to = to.joined(separator: ", ") }
            if !cc.isEmpty { composition.cc = cc.joined(separator: ", ") }
        } else {
            guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else {
                throw Problem.invalid("Give at least one recipient in to, cc, or bcc.")
            }
            composition = MailComposition(accountID: account.id, to: to.joined(separator: ", "), cc: cc.joined(separator: ", "),
                                          body: body)
        }
        composition.bcc = bcc.joined(separator: ", ")
        if let subject = Arguments.string(arguments, "subject") { composition.subject = subject }
        composition.attachments = files.map(\.url)
        let draftID = try await transport.saveDraft(composition)
        var answer: [String: ToolJSON] = ["draftId": .string(draftID), "to": .string(composition.to),
                                          "subject": .string(composition.subject)]
        if !files.isEmpty { answer["attachments"] = Self.attached(files) }
        return .object(answer)
    }

    /// Each attached file's name and size, as Gmail's tools answer them.
    static func attached(_ files: [GmailAttachmentFiles.Checked]) -> ToolJSON {
        .array(files.map { .object(["filename": .string($0.name), "size": .integer(Int64($0.size))]) })
    }

    /// What a draft holds, for the request card before it is sent (`GmailToolApproval`).
    func draftPreview(_ arguments: [String: ToolJSON]) async throws -> MailDraftPreview? {
        try await transport.thread(try Arguments.required(arguments, "draftId")).messages.last.map(MailDraftPreview.init)
    }

    private func send(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "draftId")
        try await transport.sendDraft(id)
        return .object(["sent": .bool(true), "draftId": .string(id)])
    }

    static func line(_ thread: MailThreadSummary) -> ToolJSON {
        var fields: [String: ToolJSON] = [
            "id": .string(thread.id.threadID),
            "from": .array(thread.senders.map { .string(MailComposition.formatted($0)) }),
            "subject": .string(thread.subject),
            "date": .string(ISO8601DateFormatter().string(from: thread.date)),
            "snippet": .string(thread.snippet),
            "unread": .bool(thread.isUnread)
        ]
        if thread.isStarred { fields["flagged"] = .bool(true) }
        if thread.hasAttachments { fields["hasAttachments"] = .bool(true) }
        if thread.hasDraft { fields["draft"] = .bool(true) }
        return .object(fields)
    }

    static func role(_ role: MailFolderRole) -> String {
        switch role {
        case .inbox: "inbox"
        case .starred: "flagged"
        case .sent: "sent"
        case .drafts: "drafts"
        case .archive: "archive"
        case .spam: "spam"
        case .trash: "trash"
        case .label: "folder"
        }
    }
}
