import Foundation
import YardletAgentTools

/// Runs one Outlook mail tool call against Microsoft Graph and answers with compact JSON text.
/// Arguments are checked before any request; a mistake the model can fix is an error result.
/// Graph's errors and a sign-in that ended are thrown to the connector center, which words them.
struct OutlookMailToolRunner {
    let api: GraphAPI
    /// The calling task's folders, where attachments may come from besides the person's own
    /// (`GmailAttachmentFiles`).
    var taskFolders: [URL] = []

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = OutlookMailToolCatalog

    /// A body is cut here, as Gmail's are.
    static let bodyLimit = 40_000

    private static let listFields = "id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime,"
        + "bodyPreview,isRead,isDraft,hasAttachments,importance,categories,flag,parentFolderId,webLink"

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.searchMessages: result = try await search(arguments)
            case Catalog.getMessage: result = try await message(arguments)
            case Catalog.listFolders: result = try await folders(arguments)
            case Catalog.createDraft: result = try await draft(arguments)
            case Catalog.sendDraft: result = try await sendDraft(arguments)
            case Catalog.sendMessage: result = try await send(arguments)
            case Catalog.updateMessage: result = try await update(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch let problem as GmailOutgoingMessage.Problem {
            return .error(problem.localizedDescription)
        } catch GraphAPI.Failure.invalidID(let id) {
            return .error("Not an ID Outlook takes: \(id)")
        }
    }

    // MARK: Reading

    private func search(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let unreadOnly = Arguments.bool(arguments["unreadOnly"]) == true
        let query = Arguments.string(arguments, "query")
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            var path = ["me", "messages"]
            if let folder = Arguments.string(arguments, "folderId") {
                path = ["me", "mailFolders", try GraphAPI.segment(folder), "messages"]
            }
            var items = [URLQueryItem(name: "$select", value: Self.listFields),
                         URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...50, fallback: 20)))]
            if let query {
                // Graph sorts search results newest first itself and takes no $orderby or $filter with them.
                items.append(URLQueryItem(name: "$search", value: "\"\(query.replacingOccurrences(of: "\"", with: "\\\""))\""))
            } else {
                items.append(URLQueryItem(name: "$orderby", value: "receivedDateTime desc"))
                if unreadOnly { items.append(URLQueryItem(name: "$filter", value: "isRead eq false")) }
            }
            list = try await api.get(path, items)
        }
        var result = GraphShape.page(list, key: "messages", Self.summary)
        if unreadOnly, query != nil, case .array(let messages)? = result["messages"] {
            var fields = result.objectValue ?? [:]
            fields["messages"] = .array(messages.filter { $0["isRead"] != .bool(true) })
            result = .object(fields)
        }
        return result
    }

    private func message(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try GraphAPI.segment(try Arguments.required(arguments, "messageId"))
        let html = Arguments.string(arguments, "format") == "html"
        let message = try await api.get(
            ["me", "messages", id],
            [URLQueryItem(name: "$select", value: Self.listFields + ",bccRecipients,replyTo,sentDateTime,body,internetMessageId"),
             URLQueryItem(name: "$expand", value: "attachments($select=id,name,contentType,size,isInline)")],
            headers: ["Prefer": "outlook.body-content-type=\"\(html ? "html" : "text")\""])
        var fields = Self.summary(message).objectValue ?? [:]
        fields["bcc"] = GraphShape.people(message["bccRecipients"])
        fields["replyTo"] = GraphShape.people(message["replyTo"])
        fields["sentDateTime"] = message["sentDateTime"]
        fields["bodyPreview"] = nil
        var body = message["body"]?["content"]?.stringValue ?? ""
        // A message Graph could not turn into text still reads as text.
        if !html, message["body"]?["contentType"]?.stringValue?.lowercased() == "html" {
            body = GmailText.plainText(fromHTML: body)
        }
        let (text, cut) = GraphShape.cut(body, Self.bodyLimit)
        fields[html ? "htmlBody" : "body"] = .string(text)
        if cut { fields["bodyTruncated"] = .bool(true) }
        let attachments = (message["attachments"]?.arrayValue ?? []).map {
            ToolJSON.object(Arguments.pick($0, ["id", "name", "contentType", "size", "isInline"]))
        }
        if !attachments.isEmpty { fields["attachments"] = .array(attachments) }
        return .object(fields)
    }

    private func folders(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            var path = ["me", "mailFolders"]
            if let parent = Arguments.string(arguments, "parentFolderId") {
                path += [try GraphAPI.segment(parent), "childFolders"]
            }
            list = try await api.get(path, [URLQueryItem(name: "$top", value: "100")])
        }
        return GraphShape.page(list, key: "folders") {
            .object(Arguments.pick($0, ["id", "displayName", "parentFolderId", "unreadItemCount", "totalItemCount", "childFolderCount"]))
        }
    }

    /// What a draft holds, for the request card before it is sent (`GmailToolApproval`).
    func draftPreview(_ arguments: [String: ToolJSON]) async throws -> MailDraftPreview? {
        let id = try GraphAPI.segment(try Arguments.required(arguments, "draftId"))
        let json = try await api.get(
            ["me", "messages", id],
            [URLQueryItem(name: "$select", value: "id,subject,toRecipients,ccRecipients,bccRecipients,isDraft,createdDateTime,"
                + "lastModifiedDateTime,body"),
             URLQueryItem(name: "$expand", value: "attachments($select=id,name,size,isInline)")],
            headers: ["Prefer": "outlook.body-content-type=\"text\""])
        guard var message = OutlookMailTransport.message(json)?.message else { return nil }
        message.date = OutlookMailTransport.date(json["lastModifiedDateTime"]) ?? message.date
        message.attachments = (json["attachments"]?.arrayValue ?? []).filter { $0["isInline"] != .bool(true) }.map {
            MailAttachment(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "",
                           size: OutlookMailTransport.integer($0["size"]) ?? 0, mimeType: "")
        }
        return MailDraftPreview(message)
    }

    static func summary(_ message: ToolJSON) -> ToolJSON {
        var fields = Arguments.pick(message, ["id", "conversationId", "subject", "receivedDateTime", "bodyPreview", "isRead",
                                              "isDraft", "hasAttachments", "categories", "parentFolderId", "webLink"])
        if let from = GraphShape.person(message["from"]) { fields["from"] = from }
        fields["to"] = GraphShape.people(message["toRecipients"])
        let cc = GraphShape.people(message["ccRecipients"])
        if cc.arrayValue?.isEmpty == false { fields["cc"] = cc }
        if let importance = message["importance"]?.stringValue, importance != "normal" { fields["importance"] = .string(importance) }
        if let flag = message["flag"]?["flagStatus"]?.stringValue, flag != "notFlagged" { fields["flag"] = .string(flag) }
        return .object(fields)
    }

    // MARK: Writing

    /// Graph's message fields for what the call gives: recipients, subject, and body.
    private func outgoing(_ arguments: [String: ToolJSON], body includeBody: Bool) throws -> [String: ToolJSON] {
        var message: [String: ToolJSON] = [:]
        for (argument, field) in [("to", "toRecipients"), ("cc", "ccRecipients"), ("bcc", "bccRecipients")] {
            let addresses = try Arguments.strings(arguments, argument)
            if !addresses.isEmpty { message[field] = try GraphShape.recipients(addresses, field: argument) }
        }
        if let subject = Arguments.string(arguments, "subject") { message["subject"] = .string(subject) }
        if includeBody, let content = try bodyContent(arguments) {
            message["body"] = .object(["contentType": .string(content.html ? "HTML" : "Text"), "content": .string(content.text)])
        }
        return message
    }

    private func bodyContent(_ arguments: [String: ToolJSON]) throws -> (text: String, html: Bool)? {
        if let html = arguments["htmlBody"]?.stringValue, !html.isEmpty { return (html, true) }
        if let text = arguments["body"]?.stringValue { return (text, false) }
        return nil
    }

    /// A reply's request: the text as a comment, which keeps the quoted original below it, or an
    /// HTML body in its place; recipients given replace the reply's own.
    private func replyBody(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let content = try bodyContent(arguments)
        let message = try outgoing(arguments, body: content?.html == true)
        var body: [String: ToolJSON] = [:]
        if let content, !content.html { body["comment"] = .string(content.text) }
        if !message.isEmpty { body["message"] = .object(message) }
        return .object(body)
    }

    /// The files the call attaches, checked before any request: Gmail's rules (`GmailAttachmentFiles`),
    /// and no more in one file than a single request to Graph carries.
    private func attachments(_ arguments: [String: ToolJSON]) throws -> [GmailAttachmentFiles.Checked] {
        let files = try GmailAttachmentFiles.check(try Arguments.strings(arguments, "attachments"),
                                                   roots: GmailAttachmentFiles.roots(taskFolders: taskFolders))
        if let large = files.first(where: { $0.size > OutlookMailTransport.attachmentLimit }) {
            throw GmailOutgoingMessage.Problem.unattachable(path: large.path, reason: "Outlook takes at most 3 MB in one file.")
        }
        return files
    }

    /// A draft of what the call gives, in Drafts: a reply in the original's conversation, or a new message.
    private func saveDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        if let original = Arguments.string(arguments, "replyToMessageId") {
            let action = Arguments.bool(arguments["replyAll"]) == true ? "createReplyAll" : "createReply"
            return try await api.post(["me", "messages", try GraphAPI.segment(original), action], try replyBody(arguments))
        }
        return try await api.post(["me", "messages"], .object(try outgoing(arguments, body: true)))
    }

    private func draft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let files = try attachments(arguments)
        let draft = try await saveDraft(arguments)
        if !files.isEmpty {
            guard let id = draft["id"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
            try await OutlookMailTransport.attach(files.map(\.url), to: id, api: api)
        }
        var fields = Arguments.pick(draft, ["id", "conversationId", "subject", "webLink"])
        fields["to"] = GraphShape.people(draft["toRecipients"])
        if !files.isEmpty { fields["attachments"] = MailAccountToolRunner.attached(files) }
        return .object(fields)
    }

    private func sendDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "draftId")
        _ = try await api.post(["me", "messages", try GraphAPI.segment(id), "send"], .object([:]))
        return .object(["sent": .bool(true), "draftId": .string(id)])
    }

    /// A reply goes as Graph's reply, a new message through sendMail. Graph adds files only to a saved
    /// message, so one with files is saved as a draft, given them, and sent, as Outlook sends one; a
    /// draft whose files could not all be added is deleted rather than left in Drafts.
    private func send(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let files = try attachments(arguments)
        let original = Arguments.string(arguments, "replyToMessageId")
        let message = try outgoing(arguments, body: true)
        guard original != nil || message["toRecipients"] != nil || message["ccRecipients"] != nil
                || message["bccRecipients"] != nil else {
            throw Problem.missing("to")
        }
        var result: [String: ToolJSON] = ["sent": .bool(true)]
        if let original { result["replyTo"] = .string(original) }
        if !files.isEmpty {
            guard let id = try await saveDraft(arguments)["id"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
            let draft = try GraphAPI.segment(id)
            do {
                try await OutlookMailTransport.attach(files.map(\.url), to: id, api: api)
            } catch {
                try? await api.delete(["me", "messages", draft])
                throw error
            }
            _ = try await api.post(["me", "messages", draft, "send"], .object([:]))
            result["attachments"] = MailAccountToolRunner.attached(files)
        } else if let original {
            let action = Arguments.bool(arguments["replyAll"]) == true ? "replyAll" : "reply"
            _ = try await api.post(["me", "messages", try GraphAPI.segment(original), action], try replyBody(arguments))
        } else {
            _ = try await api.post(["me", "sendMail"], .object(["message": .object(message), "saveToSentItems": .bool(true)]))
        }
        return .object(result)
    }

    private func update(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "messageId")
        var change: [String: ToolJSON] = [:]
        if let read = Arguments.bool(arguments["isRead"]) { change["isRead"] = .bool(read) }
        if let flag = Arguments.string(arguments, "flag") {
            guard Catalog.flags.contains(flag) else { throw Problem.invalid("flag is flagged, complete, or notFlagged.") }
            change["flag"] = .object(["flagStatus": .string(flag)])
        }
        if arguments["categories"] != nil { change["categories"] = .array(try Arguments.strings(arguments, "categories").map(ToolJSON.string)) }
        let destination = Arguments.string(arguments, "moveToFolderId")
        guard !change.isEmpty || destination != nil else {
            throw Problem.invalid("Give isRead, flag, categories, or moveToFolderId.")
        }
        var message: ToolJSON = .object([:])
        if !change.isEmpty { message = try await api.patch(["me", "messages", try GraphAPI.segment(id)], .object(change)) }
        if let destination {
            message = try await api.post(["me", "messages", try GraphAPI.segment(id), "move"],
                                         .object(["destinationId": .string(destination)]))
        }
        var fields = Arguments.pick(message, ["id", "isRead", "categories", "parentFolderId"])
        if let flag = message["flag"]?["flagStatus"] { fields["flag"] = flag }
        if fields["id"] == nil { fields["id"] = .string(id) }
        return .object(fields)
    }
}
