import Foundation
import YardletAgentTools

/// The mailbox's Microsoft account (Microsoft 365 or Outlook.com), through Microsoft Graph v1.0 with the
/// account's connector sign-in (`Mail.ReadWrite`, `Mail.Send`; no other permission). A thread is an
/// Outlook conversation (`conversationId`); lists are a folder's newest messages gathered by
/// conversation, and a thread is read in full only when opened. Reading never marks anything read.
struct OutlookMailTransport: MailAccountTransport {
    let api: GraphAPI
    let account: MailAccount
    static let pageSize = 50

    /// The fields a list reads of each message; no body.
    static let listFields = "id,conversationId,subject,from,toRecipients,receivedDateTime,isRead,flag,hasAttachments,"
        + "bodyPreview,isDraft,webLink,inferenceClassification"

    /// Outlook's own folders by their well-known names, in the mailbox's order of roles.
    static let wellKnown: [(name: String, role: MailFolderRole)] = [
        ("inbox", .inbox), ("sentitems", .sent), ("drafts", .drafts), ("archive", .archive),
        ("junkemail", .spam), ("deleteditems", .trash),
    ]

    // MARK: - Folders and lists

    /// Outlook's well-known folders as the mailbox names them in the account's own language, then the
    /// account's other top-level folders by name.
    func folders() async throws -> [MailFolder] {
        var folders: [MailFolder] = []
        for known in Self.wellKnown {
            // An account without an Archive folder answers 404 for it.
            guard let json = try? await api.get(["me", "mailFolders", known.name],
                                                [URLQueryItem(name: "$select", value: "id,displayName,unreadItemCount,totalItemCount")]),
                  let id = json["id"]?.stringValue else { continue }
            let count = known.role == .drafts ? Self.integer(json["totalItemCount"]) : Self.integer(json["unreadItemCount"])
            folders.append(MailFolder(id: id, name: json["displayName"]?.stringValue ?? known.name, role: known.role,
                                      unreadCount: known.role == .inbox || known.role == .spam || known.role == .drafts ? count : nil))
        }
        let known = Set(folders.map(\.id))
        let list = try await api.get(["me", "mailFolders"], [URLQueryItem(name: "$top", value: "100"),
                                                             URLQueryItem(name: "$select", value: "id,displayName,unreadItemCount")])
        let others = (list["value"]?.arrayValue ?? []).compactMap { folder -> MailFolder? in
            guard let id = folder["id"]?.stringValue, !known.contains(id), let name = folder["displayName"]?.stringValue else { return nil }
            return MailFolder(id: id, name: name, role: .label, unreadCount: Self.integer(folder["unreadItemCount"]))
        }
        return folders + others.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func inbox(pageToken: String?) async throws -> MailPage {
        try await page(["me", "mailFolders", "inbox", "messages"], pageToken: pageToken)
    }

    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage {
        try await page(["me", "mailFolders", try GraphAPI.segment(folder.id), "messages"], pageToken: pageToken)
    }

    /// Graph's search over the whole mailbox (KQL); Graph answers a search by relevance and date.
    func search(_ query: String, pageToken: String?) async throws -> MailPage {
        let json: ToolJSON
        if let pageToken {
            json = try await api.get(page: pageToken)
        } else {
            let quoted = "\"" + query.replacingOccurrences(of: "\"", with: "") + "\""
            json = try await api.get(["me", "messages"], [URLQueryItem(name: "$search", value: quoted),
                                                          URLQueryItem(name: "$top", value: String(Self.pageSize)),
                                                          URLQueryItem(name: "$select", value: Self.listFields)])
        }
        return MailPage(threads: Self.threads(json["value"]?.arrayValue ?? [], account: account),
                        nextPageToken: json["@odata.nextLink"]?.stringValue)
    }

    private func page(_ path: [String], pageToken: String?) async throws -> MailPage {
        let json = if let pageToken {
            try await api.get(page: pageToken)
        } else {
            try await api.get(path, [URLQueryItem(name: "$top", value: String(Self.pageSize)),
                                     URLQueryItem(name: "$select", value: Self.listFields),
                                     URLQueryItem(name: "$orderby", value: "receivedDateTime desc")])
        }
        return MailPage(threads: Self.threads(json["value"]?.arrayValue ?? [], account: account),
                        nextPageToken: json["@odata.nextLink"]?.stringValue)
    }

    /// Messages newest first gathered into one line per conversation, in the order its newest message
    /// came.
    static func threads(_ messages: [ToolJSON], account: MailAccount) -> [MailThreadSummary] {
        var order: [String] = []
        var byConversation: [String: [ToolJSON]] = [:]
        for message in messages {
            guard let conversation = message["conversationId"]?.stringValue ?? message["id"]?.stringValue else { continue }
            if byConversation[conversation] == nil { order.append(conversation) }
            byConversation[conversation, default: []].append(message)
        }
        return order.compactMap { conversation in
            summary(conversation: conversation, messages: byConversation[conversation] ?? [], account: account)
        }
    }

    /// A conversation's line from its messages, newest first.
    static func summary(conversation: String, messages: [ToolJSON], account: MailAccount) -> MailThreadSummary? {
        let sent = messages.filter { $0["isDraft"] != .bool(true) }
        guard let newest = sent.first ?? messages.first else { return nil }
        var senders: [MailAddress] = []
        for message in sent {
            if let sender = person(message["from"]), !senders.contains(where: {
                $0.address.caseInsensitiveCompare(sender.address) == .orderedSame
            }) { senders.append(sender) }
        }
        return MailThreadSummary(
            id: MailThreadKey(accountID: account.id, threadID: conversation),
            subject: (messages.last ?? newest)["subject"]?.stringValue ?? "",
            senders: senders,
            snippet: newest["bodyPreview"]?.stringValue ?? "",
            date: date(newest["receivedDateTime"]) ?? .distantPast,
            messageCount: max(sent.count, 1),
            isUnread: sent.contains { $0["isRead"] == .bool(false) },
            isStarred: messages.contains { $0["flag"]?["flagStatus"]?.stringValue == "flagged" },
            hasAttachments: messages.contains { $0["hasAttachments"] == .bool(true) },
            hasDraft: messages.contains { $0["isDraft"] == .bool(true) })
    }

    // MARK: - A thread

    /// Every message of the conversation, in every folder, oldest first, with its HTML.
    func thread(_ threadID: String) async throws -> MailThread {
        let messages = try await conversation(threadID, fields: Self.listFields + ",ccRecipients,bccRecipients,replyTo,"
            + "internetMessageId,createdDateTime,body,parentFolderId", html: true)
        guard let summary = Self.summary(conversation: threadID, messages: Array(messages.reversed()), account: account) else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This message could not be read"))
        }
        let read = messages.compactMap(Self.message)
        let attachments = try await withThrowingTaskGroup(of: (String, [MailAttachment]).self) { group in
            for message in read where message.hasFiles {
                group.addTask { (message.id, try await files(of: message.id)) }
            }
            var found: [String: [MailAttachment]] = [:]
            for try await (id, files) in group { found[id] = files }
            return found
        }
        let webLink = messages.last { $0["isDraft"] != .bool(true) }?["webLink"]?.stringValue
        return MailThread(summary: summary,
                          messages: read.map { message in
                              var message = message.message
                              message.attachments = attachments[message.id] ?? []
                              return message
                          },
                          webURL: webLink.flatMap(URL.init(string:)))
    }

    /// The conversation's messages oldest first. Graph takes no `$orderby` with this filter, so they are
    /// put in order here.
    private func conversation(_ id: String, fields: String, html: Bool = false) async throws -> [ToolJSON] {
        let quoted = id.replacingOccurrences(of: "'", with: "''")
        var json = try await api.get(["me", "messages"], [URLQueryItem(name: "$filter", value: "conversationId eq '\(quoted)'"),
                                                          URLQueryItem(name: "$top", value: "100"),
                                                          URLQueryItem(name: "$select", value: fields)],
                                     headers: html ? ["Prefer": "outlook.body-content-type=\"html\""] : [:])
        var messages = json["value"]?.arrayValue ?? []
        while let next = json["@odata.nextLink"]?.stringValue, messages.count < 500 {
            json = try await api.get(page: next, headers: html ? ["Prefer": "outlook.body-content-type=\"html\""] : [:])
            messages += json["value"]?.arrayValue ?? []
        }
        return messages.sorted { (Self.date($0["receivedDateTime"]) ?? .distantPast) < (Self.date($1["receivedDateTime"]) ?? .distantPast) }
    }

    private func files(of messageID: String) async throws -> [MailAttachment] {
        let json = try await api.get(["me", "messages", try GraphAPI.segment(messageID), "attachments"],
                                     [URLQueryItem(name: "$select", value: "id,name,size,contentType,isInline")])
        return (json["value"]?.arrayValue ?? []).compactMap { file in
            guard file["isInline"] != .bool(true), let id = file["id"]?.stringValue else { return nil }
            return MailAttachment(id: id, name: file["name"]?.stringValue ?? "", size: Self.integer(file["size"]) ?? 0,
                                  mimeType: file["contentType"]?.stringValue ?? "application/octet-stream")
        }
    }

    /// A message read in full, and whether it has files to list.
    static func message(_ json: ToolJSON) -> (message: MailMessage, hasFiles: Bool, id: String)? {
        guard let id = json["id"]?.stringValue else { return nil }
        let html = json["body"]?["contentType"]?.stringValue?.lowercased() == "html" ? json["body"]?["content"]?.stringValue : nil
        let text = html.map(GmailText.plainText(fromHTML:)) ?? json["body"]?["content"]?.stringValue ?? ""
        let isDraft = json["isDraft"] == .bool(true)
        let message = MailMessage(
            id: id,
            from: person(json["from"]) ?? MailAddress(address: ""),
            to: people(json["toRecipients"]), cc: people(json["ccRecipients"]), bcc: people(json["bccRecipients"]),
            date: date(json[isDraft ? "createdDateTime" : "receivedDateTime"]) ?? date(json["receivedDateTime"]) ?? .distantPast,
            subject: json["subject"]?.stringValue ?? "",
            snippet: json["bodyPreview"]?.stringValue ?? "",
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            html: html,
            attachments: [],
            isDraft: isDraft,
            isUnread: json["isRead"] == .bool(false),
            messageID: json["internetMessageId"]?.stringValue,
            replyTo: people(json["replyTo"]))
        return (message, json["hasAttachments"] == .bool(true), id)
    }

    // MARK: - Changes

    /// Outlook keeps read state per message, so a thread is changed message by message: read or unread,
    /// the newest flagged (or every flag cleared), or its messages in the inbox, spam or the trash moved.
    func change(_ threadID: String, _ change: MailThreadChange) async throws {
        let messages = try await conversation(threadID, fields: "id,isRead,isDraft,flag,parentFolderId")
        func patch(_ message: ToolJSON, _ body: ToolJSON) async throws {
            guard let id = message["id"]?.stringValue else { return }
            _ = try await api.patch(["me", "messages", try GraphAPI.segment(id)], body)
        }
        func move(from folder: String, to destination: String) async throws {
            let source = try await api.get(["me", "mailFolders", folder], [URLQueryItem(name: "$select", value: "id")])["id"]?.stringValue
            for message in messages where message["parentFolderId"]?.stringValue == source {
                guard let id = message["id"]?.stringValue else { continue }
                _ = try await api.post(["me", "messages", try GraphAPI.segment(id), "move"], .object(["destinationId": .string(destination)]))
            }
        }
        switch change {
        case let .read(read):
            for message in messages where message["isDraft"] != .bool(true) && message["isRead"] != .bool(read) {
                try await patch(message, .object(["isRead": .bool(read)]))
            }
        case .starred(true):
            if let newest = messages.last(where: { $0["isDraft"] != .bool(true) }) {
                try await patch(newest, .object(["flag": .object(["flagStatus": .string("flagged")])]))
            }
        case .starred(false):
            for message in messages where message["flag"]?["flagStatus"]?.stringValue == "flagged" {
                try await patch(message, .object(["flag": .object(["flagStatus": .string("notFlagged")])]))
            }
        case .archived: try await move(from: "inbox", to: "archive")
        case .notSpam: try await move(from: "junkemail", to: "inbox")
        case .untrash: try await move(from: "deleteditems", to: "inbox")
        }
    }

    // MARK: - Drafts

    /// A new message is a draft in Drafts; a reply, reply to all or forward starts from Graph's own
    /// (`createReply`, `createReplyAll`, `createForward`), which threads it and carries a forward's files.
    /// Then what the person wrote replaces its fields, and chosen files are added once each, up to the 3 MB
    /// a single request carries.
    func saveDraft(_ composition: MailComposition) async throws -> String {
        var fields: [String: ToolJSON] = [
            "subject": .string(composition.subject),
            "body": .object(["contentType": .string("Text"), "content": .string(composition.body)]),
            "toRecipients": Self.recipients(composition.to),
            "ccRecipients": Self.recipients(composition.cc),
            "bccRecipients": Self.recipients(composition.bcc),
        ]
        let draftID: String
        if let id = composition.draftID {
            draftID = id
            _ = try await api.patch(["me", "messages", try GraphAPI.segment(id)], .object(fields))
        } else if composition.kind != .new, let answered = composition.replyToMessageID {
            let action = switch composition.kind {
            case .replyAll: "createReplyAll"
            case .forward: "createForward"
            default: "createReply"
            }
            let created = try await api.post(["me", "messages", try GraphAPI.segment(answered), action], .object([:]))
            guard let id = created["id"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
            draftID = id
            _ = try await api.patch(["me", "messages", try GraphAPI.segment(id)], .object(fields))
        } else {
            fields["isDraft"] = .bool(true)
            let created = try await api.post(["me", "messages"], .object(fields))
            guard let id = created["id"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
            draftID = id
        }
        guard !composition.attachments.isEmpty else { return draftID }
        let present = Set(try await files(of: draftID).map(\.name))
        try await Self.attach(composition.attachments.filter { !present.contains(GmailAttachmentFiles.displayName($0.path)) },
                              to: draftID, api: api)
        return draftID
    }

    /// The most one request attaches; larger files need an upload session.
    static let attachmentLimit = 3 * 1024 * 1024

    /// Adds the files to a saved message, one request each, as the mailbox and Outlook's tools both do.
    static func attach(_ files: [URL], to messageID: String, api: GraphAPI) async throws {
        for url in files {
            let name = GmailAttachmentFiles.displayName(url.path)
            let data = try Data(contentsOf: url)
            guard data.count <= attachmentLimit else { throw GraphAPI.Failure.tooLarge(bytes: data.count, limit: attachmentLimit) }
            _ = try await api.post(["me", "messages", try GraphAPI.segment(messageID), "attachments"], .object([
                "@odata.type": .string("#microsoft.graph.fileAttachment"),
                "name": .string(name),
                "contentType": .string(FileTypes.mimeType(forExtension: url.pathExtension) ?? "application/octet-stream"),
                "contentBytes": .string(data.base64EncodedString()),
            ]))
        }
    }

    func sendDraft(_ draftID: String) async throws {
        _ = try await api.post(["me", "messages", try GraphAPI.segment(draftID), "send"], .object([:]))
    }

    func discardDraft(_ draftID: String) async throws {
        try await api.delete(["me", "messages", try GraphAPI.segment(draftID)])
    }

    /// An Outlook draft is a message in Drafts, known by its own ID.
    func draftID(forMessage messageID: String) async throws -> String { messageID }

    // MARK: - New mail

    /// The inbox's changes from now on: a delta query over the last day's mail, followed to its
    /// `deltaLink`, with the time it was taken.
    func changeCursor() async throws -> String {
        let since = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-86_400))
        // The link Graph gives back keeps this selection, so it names what `changes` reads.
        var json = try await api.get(["me", "mailFolders", "inbox", "messages", "delta"],
                                     [URLQueryItem(name: "$select", value: "id,conversationId,isRead,isDraft,receivedDateTime,inferenceClassification"),
                                      URLQueryItem(name: "$filter", value: "receivedDateTime ge \(since)")])
        while let next = json["@odata.nextLink"]?.stringValue { json = try await api.get(page: next) }
        guard let link = json["@odata.deltaLink"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
        return Self.cursor(link, at: .now)
    }

    /// What changed in the inbox after the cursor: any message is a change, and an unread one that came
    /// after the cursor was taken, not a draft and in the Focused inbox where Outlook sorts, arrived. A
    /// link Graph no longer knows starts again.
    func changes(since cursor: String) async throws -> MailChanges {
        guard let (link, taken) = Self.parse(cursor) else {
            return MailChanges(cursor: try await changeCursor(), changed: true, arrivedThreadIDs: [])
        }
        var json: ToolJSON
        do {
            json = try await api.get(page: link, headers: ["Prefer": "odata.maxpagesize=100"])
        } catch GraphAPI.Failure.http(status: 410, _) {
            return MailChanges(cursor: try await changeCursor(), changed: true, arrivedThreadIDs: [])
        }
        var items = json["value"]?.arrayValue ?? []
        while let next = json["@odata.nextLink"]?.stringValue {
            json = try await api.get(page: next)
            items += json["value"]?.arrayValue ?? []
        }
        guard let deltaLink = json["@odata.deltaLink"]?.stringValue else { throw GraphAPI.Failure.unreadableAnswer }
        var arrived: [String] = []
        for item in items where item["@removed"] == nil {
            guard item["isRead"] == .bool(false), item["isDraft"] != .bool(true),
                  item["inferenceClassification"]?.stringValue != "other",
                  let received = Self.date(item["receivedDateTime"]), received > taken,
                  let conversation = item["conversationId"]?.stringValue, !arrived.contains(conversation) else { continue }
            arrived.append(conversation)
        }
        return MailChanges(cursor: Self.cursor(deltaLink, at: .now), changed: !items.isEmpty, arrivedThreadIDs: arrived)
    }

    /// The delta link and when it was taken, kept together as one cursor.
    static func cursor(_ link: String, at date: Date) -> String {
        "\(Int(date.timeIntervalSince1970))|\(link)"
    }

    static func parse(_ cursor: String) -> (link: String, taken: Date)? {
        guard let bar = cursor.firstIndex(of: "|"), let seconds = Double(cursor[..<bar]) else { return nil }
        return (String(cursor[cursor.index(after: bar)...]), Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Graph's shapes

    static func person(_ recipient: ToolJSON?) -> MailAddress? {
        guard let address = recipient?["emailAddress"]?["address"]?.stringValue, !address.isEmpty else { return nil }
        return MailAddress(name: recipient?["emailAddress"]?["name"]?.stringValue, address: address)
    }

    static func people(_ recipients: ToolJSON?) -> [MailAddress] {
        (recipients?.arrayValue ?? []).compactMap(person)
    }

    /// The typed field as Graph's recipients.
    static func recipients(_ field: String) -> ToolJSON {
        .array(MailAddressList.parse(field).map { address in
            var email: [String: ToolJSON] = ["address": .string(address.address)]
            if let name = address.name { email["name"] = .string(name) }
            return .object(["emailAddress": .object(email)])
        })
    }

    static func date(_ value: ToolJSON?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func integer(_ value: ToolJSON?) -> Int? {
        switch value {
        case .integer(let number)?: Int(exactly: number)
        case .number(let number)?: Int(exactly: number.rounded())
        default: nil
        }
    }
}
