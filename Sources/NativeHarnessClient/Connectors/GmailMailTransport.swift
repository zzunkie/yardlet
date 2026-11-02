import Foundation
import YardletAgentTools

/// The mailbox's Gmail account, through the Gmail API with the account's connector sign-in
/// (`gmail.modify`; no other scope). The inbox and searches are thread lists with each thread's
/// headers; a thread is read in full only when it is opened. Reading never marks anything read: the
/// mailbox asks for that separately (`MailReadSync`).
struct GmailMailTransport: MailAccountTransport {
    let api: GmailAPI
    let account: MailAccount
    /// Threads read at once for a list's headers, as the connector's `search_threads` does.
    static let parallelReads = 5
    static let pageSize = 50

    func inbox(pageToken: String?) async throws -> MailPage {
        try await list([URLQueryItem(name: "labelIds", value: "INBOX")], pageToken: pageToken)
    }

    /// Gmail's own mailboxes in the order its web app lists them, All Mail for the archive, then the
    /// labels the person shows in Gmail's label list, by name. Unread counts are read for the inbox and
    /// spam, and the drafts count as Gmail shows it (`labels.get`, one request each).
    func folders() async throws -> [MailFolder] {
        let json = try await api.get("users/me/labels")
        let labels = json["labels"]?.arrayValue ?? []
        var folders = Self.systemFolders
        async let inbox = count("INBOX", unread: true)
        async let spam = count("SPAM", unread: true)
        async let drafts = count("DRAFT", unread: false)
        let counts = await ["INBOX": inbox, "SPAM": spam, "DRAFT": drafts]
        for index in folders.indices { folders[index].unreadCount = counts[folders[index].id] ?? nil }
        let user = labels.filter { $0["type"]?.stringValue == "user" && $0["labelListVisibility"]?.stringValue != "labelHide" }
            .compactMap { label -> (id: String, path: String)? in
                guard let id = label["id"]?.stringValue, let name = label["name"]?.stringValue else { return nil }
                return (id, name)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        folders += user.map { label in
            let parts = label.path.split(separator: "/")
            return MailFolder(id: label.id, name: parts.last.map(String.init) ?? label.path, role: .label,
                              depth: max(parts.count - 1, 0))
        }
        return folders
    }

    /// Gmail's system labels the mailbox shows, and All Mail, which has no label.
    static let allMail = "ALL"
    static var systemFolders: [MailFolder] {
        [MailFolder(id: "INBOX", name: L10n.string("Mail inbox"), role: .inbox),
         MailFolder(id: "STARRED", name: L10n.string("Mail starred"), role: .starred),
         MailFolder(id: "SENT", name: L10n.string("Mail sent"), role: .sent),
         MailFolder(id: "DRAFT", name: L10n.string("Mail drafts"), role: .drafts),
         MailFolder(id: allMail, name: L10n.string("Mail all mail"), role: .archive),
         MailFolder(id: "SPAM", name: L10n.string("Mail spam"), role: .spam),
         MailFolder(id: "TRASH", name: L10n.string("Mail trash"), role: .trash)]
    }

    private func count(_ label: String, unread: Bool) async -> Int? {
        guard let json = try? await api.get("users/me/labels/\(label)") else { return nil }
        return Self.integer(json[unread ? "threadsUnread" : "threadsTotal"])
    }

    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage {
        var query: [URLQueryItem] = []
        if folder.id != Self.allMail { query.append(URLQueryItem(name: "labelIds", value: try GmailAPI.segment(folder.id))) }
        if folder.role.isSetAside { query.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        return try await list(query, pageToken: pageToken)
    }

    func search(_ query: String, pageToken: String?) async throws -> MailPage {
        try await list([URLQueryItem(name: "q", value: query)], pageToken: pageToken)
    }

    func thread(_ threadID: String) async throws -> MailThread {
        let json = try await api.get("users/me/threads/\(try GmailAPI.segment(threadID))",
                                     [URLQueryItem(name: "format", value: "full")])
        let messages = (json["messages"]?.arrayValue ?? []).map(GmailMessage.init(json:))
        guard let summary = Self.summary(threadID: threadID, messages: messages, account: account) else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This message could not be read"))
        }
        return MailThread(summary: summary, messages: messages.compactMap(Self.message), webURL: webURL(threadID))
    }

    func change(_ threadID: String, _ change: MailThreadChange) async throws {
        if change == .untrash {
            _ = try await api.post("users/me/threads/\(try GmailAPI.segment(threadID))/untrash", .object([:]))
            return
        }
        let (add, remove): ([String], [String]) = switch change {
        case .read(true): ([], ["UNREAD"])
        case .read(false): (["UNREAD"], [])
        case .starred(true): (["STARRED"], [])
        case .starred(false): ([], ["STARRED"])
        case .archived: ([], ["INBOX"])
        case .notSpam: (["INBOX"], ["SPAM"])
        case .untrash: ([], [])
        }
        _ = try await api.post("users/me/threads/\(try GmailAPI.segment(threadID))/modify", .object([
            "addLabelIds": .array(add.map { .string($0) }),
            "removeLabelIds": .array(remove.map { .string($0) }),
        ]))
    }

    // MARK: - Drafts

    /// The draft as MIME: the typed recipients, the subject and text, a reply's `In-Reply-To` and
    /// `References`, the chosen files and, for a forward, the original's files, within Gmail's 25 MB.
    /// A draft with files goes through the upload endpoint; changing one replaces it with a new draft.
    func saveDraft(_ composition: MailComposition) async throws -> String {
        var message = GmailOutgoingMessage()
        message.to = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.to))
        message.cc = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.cc))
        message.bcc = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.bcc))
        message.subject = composition.subject
        message.body = composition.body
        message.inReplyTo = composition.inReplyTo
        message.references = composition.references
        message.attachments = try composition.attachments.map { url in
            GmailOutgoingMessage.Attachment(filename: GmailAttachmentFiles.displayName(url.path),
                                            mimeType: FileTypes.mimeType(forExtension: url.pathExtension) ?? "application/octet-stream",
                                            data: try Data(contentsOf: url))
        }
        if let forwarded = composition.forwardedMessageID { message.attachments += try await files(of: forwarded) }
        let bytes = message.attachments.reduce(0) { $0 + $1.data.count }
        guard bytes <= GmailAttachmentFiles.limit else { throw GmailOutgoingMessage.Problem.attachmentsTooLarge(bytes: bytes) }
        var draft: [String: ToolJSON] = [:]
        if let thread = composition.threadID { draft["threadId"] = .string(try GmailAPI.segment(thread)) }
        let answer: ToolJSON
        if message.attachments.isEmpty {
            draft["raw"] = .string(message.raw)
            if let id = composition.draftID {
                answer = try await api.put("users/me/drafts/\(try GmailAPI.segment(id))", .object(["message": .object(draft)]))
            } else {
                answer = try await api.post("users/me/drafts", .object(["message": .object(draft)]))
            }
        } else {
            if let id = composition.draftID { try await discardDraft(id) }
            answer = try await api.upload("users/me/drafts", metadata: .object(["message": .object(draft)]),
                                          message: Data(message.mime.utf8))
        }
        guard let id = answer["id"]?.stringValue else { throw GmailAPI.Failure.unreadableAnswer }
        return id
    }

    func sendDraft(_ draftID: String) async throws {
        _ = try await api.post("users/me/drafts/send", .object(["id": .string(try GmailAPI.segment(draftID))]))
    }

    func discardDraft(_ draftID: String) async throws {
        try await api.delete("users/me/drafts/\(try GmailAPI.segment(draftID))")
    }

    /// Gmail addresses drafts by their own ID; the thread lists the draft's message.
    func draftID(forMessage messageID: String) async throws -> String {
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "500")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let json = try await api.get("users/me/drafts", query)
            if let draft = json["drafts"]?.arrayValue?.first(where: { $0["message"]?["id"]?.stringValue == messageID }),
               let id = draft["id"]?.stringValue {
                return id
            }
            pageToken = json["nextPageToken"]?.stringValue
        } while pageToken != nil
        throw MailFailure(kind: .unavailable, message: L10n.string("This draft is no longer in the account."))
    }

    /// A message's attached files with their content, for a forward.
    private func files(of messageID: String) async throws -> [GmailOutgoingMessage.Attachment] {
        let id = try GmailAPI.segment(messageID)
        let json = try await api.get("users/me/messages/\(id)", [URLQueryItem(name: "format", value: "full")])
        var files: [GmailOutgoingMessage.Attachment] = []
        for part in Self.attachmentParts(json["payload"]) {
            var content = part.data
            if content == nil, let attachment = part.id {
                content = try await api.get("users/me/messages/\(id)/attachments/\(try GmailAPI.segment(attachment))")["data"]?.stringValue
            }
            guard let data = content.flatMap(Self.base64URL) else { throw GmailAPI.Failure.unreadableAnswer }
            files.append(GmailOutgoingMessage.Attachment(filename: part.name, mimeType: part.mimeType, data: data))
        }
        return files
    }

    private static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    func changeCursor() async throws -> String {
        guard let cursor = try await api.profile()["historyId"]?.stringValue else { throw GmailAPI.Failure.unreadableAnswer }
        return cursor
    }

    /// The inbox's history after `cursor` (`users.history.list`, 2 quota units a page): any record is a
    /// change, and a message added to the inbox unread, not sent or drafted by the account and in the
    /// Primary category, arrived. Gmail keeps history for at least a week; an older cursor answers 404.
    func changes(since cursor: String) async throws -> MailChanges {
        var next = cursor
        var changed = false
        var arrived: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "startHistoryId", value: cursor), URLQueryItem(name: "labelId", value: "INBOX")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let json: ToolJSON
            do {
                json = try await api.get("users/me/history", query)
            } catch GmailAPI.Failure.http(status: 404, _) {
                return MailChanges(cursor: try await changeCursor(), changed: true, arrivedThreadIDs: [])
            }
            let records = json["history"]?.arrayValue ?? []
            changed = changed || !records.isEmpty
            for record in records {
                for added in record["messagesAdded"]?.arrayValue ?? [] {
                    let labels = Set(added["message"]?["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                    guard let thread = added["message"]?["threadId"]?.stringValue,
                          labels.isSuperset(of: ["INBOX", "UNREAD"]), labels.isDisjoint(with: Self.notAnnounced),
                          !arrived.contains(thread) else { continue }
                    arrived.append(thread)
                }
            }
            if let historyID = json["historyId"]?.stringValue { next = historyID }
            pageToken = json["nextPageToken"]?.stringValue
        } while pageToken != nil
        return MailChanges(cursor: next, changed: changed, arrivedThreadIDs: arrived)
    }

    /// Labels of mail the person does not hear about: their own, and the other inbox categories.
    static let notAnnounced: Set<String> = ["SENT", "DRAFT", "SPAM", "TRASH", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL",
                                            "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    /// The thread in Gmail on the web, signed in as this account.
    func webURL(_ threadID: String) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        components?.queryItems = [URLQueryItem(name: "authuser", value: account.address)]
        components?.fragment = "all/\(threadID)"
        return components?.url
    }

    // MARK: - Lists

    private func list(_ query: [URLQueryItem], pageToken: String?) async throws -> MailPage {
        var items = query + [URLQueryItem(name: "maxResults", value: String(Self.pageSize))]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let json = try await api.get("users/me/threads", items)
        let ids = (json["threads"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        var summaries: [Int: MailThreadSummary] = [:]
        // Five at a time, in the list's order.
        for start in stride(from: 0, to: ids.count, by: Self.parallelReads) {
            let batch = Array(ids[start..<min(start + Self.parallelReads, ids.count)].enumerated())
            try await withThrowingTaskGroup(of: (Int, MailThreadSummary?).self) { group in
                for (offset, id) in batch {
                    group.addTask { (start + offset, try await headers(id)) }
                }
                for try await (index, summary) in group { summaries[index] = summary }
            }
        }
        return MailPage(threads: ids.indices.compactMap { summaries[$0] ?? nil },
                        nextPageToken: json["nextPageToken"]?.stringValue)
    }

    private func headers(_ threadID: String) async throws -> MailThreadSummary? {
        let json = try await api.get("users/me/threads/\(try GmailAPI.segment(threadID))", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "To"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
        ])
        return Self.summary(threadID: threadID, messages: (json["messages"]?.arrayValue ?? []).map(GmailMessage.init(json:)),
                            account: account)
    }

    // MARK: - Reading Gmail's answers

    /// A thread's line from its messages (oldest first, as Gmail lists them): the subject of the
    /// first, the newest sent message's snippet and time, every sender newest first, and whether any
    /// message is unread, starred, a draft or carries files.
    static func summary(threadID: String, messages: [GmailMessage], account: MailAccount) -> MailThreadSummary? {
        guard !messages.isEmpty else { return nil }
        let sent = messages.filter { !$0.labelIds.contains("DRAFT") }
        let newest = sent.last ?? messages[messages.count - 1]
        var senders: [MailAddress] = []
        for message in sent.reversed() {
            for sender in MailAddressList.parse(message.header("From") ?? "") where !senders.contains(where: {
                $0.address.caseInsensitiveCompare(sender.address) == .orderedSame
            }) {
                senders.append(sender)
            }
        }
        let labels = Set(messages.flatMap(\.labelIds))
        return MailThreadSummary(
            id: MailThreadKey(accountID: account.id, threadID: threadID),
            subject: messages.lazy.compactMap { $0.header("Subject") }.first ?? "",
            senders: senders,
            snippet: newest.snippet ?? "",
            date: newest.internalDate ?? .distantPast,
            messageCount: max(sent.count, 1),
            isUnread: labels.contains("UNREAD"),
            isStarred: labels.contains("STARRED"),
            hasAttachments: messages.contains { $0.json["payload"]?["mimeType"]?.stringValue?.lowercased() == "multipart/mixed" },
            hasDraft: labels.contains("DRAFT"))
    }

    /// A message read in full; nil without an ID.
    static func message(_ message: GmailMessage) -> MailMessage? {
        guard let id = message.id else { return nil }
        let parts = GmailMessage.parts(message.json["payload"])
        let text = parts.plain ?? parts.html.map(GmailText.plainText(fromHTML:)) ?? ""
        return MailMessage(
            id: id,
            from: MailAddressList.parse(message.header("From") ?? "").first ?? MailAddress(address: ""),
            to: MailAddressList.parse(message.header("To") ?? ""),
            cc: MailAddressList.parse(message.header("Cc") ?? ""),
            date: message.internalDate ?? .distantPast,
            subject: message.header("Subject") ?? "",
            snippet: message.snippet ?? "",
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            html: parts.html,
            attachments: attachmentParts(message.json["payload"]).enumerated().map { index, part in
                MailAttachment(id: part.id ?? "\(id)-\(index)", name: part.name, size: part.size, mimeType: part.mimeType)
            },
            isDraft: message.labelIds.contains("DRAFT"),
            isUnread: message.labelIds.contains("UNREAD"),
            messageID: message.header("Message-ID"),
            references: message.header("References"),
            replyTo: MailAddressList.parse(message.header("Reply-To") ?? ""))
    }

    /// A message's attached files: the ID Gmail reads a file's content by, or the content itself when
    /// Gmail put a small file in the message (it then gives no ID).
    struct AttachmentPart {
        var id: String?
        var data: String?
        var name: String
        var mimeType: String
        var size: Int
    }

    static func attachmentParts(_ payload: ToolJSON?) -> [AttachmentPart] {
        var found: [AttachmentPart] = []
        func walk(_ part: ToolJSON, depth: Int) {
            guard depth < 32 else { return }
            let mimeType = part["mimeType"]?.stringValue ?? "application/octet-stream"
            if let name = part["filename"]?.stringValue, !name.isEmpty, !mimeType.lowercased().hasPrefix("multipart/") {
                found.append(AttachmentPart(id: part["body"]?["attachmentId"]?.stringValue,
                                            data: part["body"]?["data"]?.stringValue,
                                            name: name, mimeType: mimeType, size: integer(part["body"]?["size"]) ?? 0))
            }
            for child in part["parts"]?.arrayValue ?? [] { walk(child, depth: depth + 1) }
        }
        if let payload { walk(payload, depth: 0) }
        return found
    }
}

extension GmailMailTransport {
    fileprivate static func integer(_ value: ToolJSON?) -> Int? {
        switch value {
        case .integer(let number)?: Int(exactly: number)
        case .number(let number)?: Int(exactly: number.rounded())
        case .string(let text)?: Int(text)
        default: nil
        }
    }
}

