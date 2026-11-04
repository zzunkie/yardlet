import Foundation
import YardletAgentTools

/// Runs one Gmail tool call against the Gmail API and answers with compact JSON text. Arguments
/// are checked before any request; a mistake the model can fix is an error result. Google's
/// errors and a sign-in that ended are thrown to the connector center, which words them.
struct GmailToolRunner {
    let api: GmailAPI
    /// How many thread lookups a search runs at once, within Gmail's per-user rate.
    var searchConcurrency = 5
    /// The most messages a search shows per thread, the latest ones.
    var messagesPerThread = 10
    /// The calling task's folders, where attachments may come from besides the person's own
    /// (`GmailAttachmentFiles`).
    var taskFolders: [URL] = []

    enum ArgumentError: Error, Equatable, LocalizedError {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "\(name) is required."
            case .invalid(let reason): reason
            }
        }
    }

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case GmailToolCatalog.searchThreads: result = try await searchThreads(arguments)
            case GmailToolCatalog.getThread: result = try await getThread(arguments)
            case GmailToolCatalog.getMessage: result = try await getMessage(arguments)
            case GmailToolCatalog.listLabels: result = try await listLabels()
            case GmailToolCatalog.createDraft: result = try await createDraft(arguments)
            case GmailToolCatalog.sendDraft: result = try await sendDraft(arguments)
            case GmailToolCatalog.sendMessage: result = try await sendMessage(arguments)
            case GmailToolCatalog.modifyLabels: result = try await modifyLabels(arguments)
            case GmailToolCatalog.deleteDraft: result = try await deleteDraft(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Self.text(result))
        } catch let error as ArgumentError {
            return .error(error.localizedDescription)
        } catch let error as GmailOutgoingMessage.Problem {
            return .error(error.localizedDescription)
        } catch GmailAPI.Failure.invalidID(let id) {
            return .error("Not a Gmail ID: \(id)")
        }
    }

    static func text(_ json: ToolJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Reading

    private static let summaryHeaders = ["From", "To", "Cc", "Subject", "Date"]

    private func searchThreads(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var query: [URLQueryItem] = [URLQueryItem(name: "maxResults", value: String(Self.integer(arguments["pageSize"]).map { min(max($0, 1), 50) } ?? 20))]
        if let q = arguments["query"]?.stringValue, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            query.append(URLQueryItem(name: "q", value: q))
        }
        if let token = arguments["pageToken"]?.stringValue, !token.isEmpty { query.append(URLQueryItem(name: "pageToken", value: token)) }
        if arguments["includeTrash"] == .bool(true) { query.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        let list = try await api.get("users/me/threads", query)
        let ids = (list["threads"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        let threads = try await threadSummaries(ids)
        var result: [String: ToolJSON] = ["threads": .array(threads)]
        if let next = list["nextPageToken"]?.stringValue { result["nextPageToken"] = .string(next) }
        if let estimate = list["resultSizeEstimate"] { result["resultSizeEstimate"] = estimate }
        return .object(result)
    }

    /// Each thread's messages with headers and snippet, in the search's order, a few at a time.
    private func threadSummaries(_ ids: [String]) async throws -> [ToolJSON] {
        let headers = Self.summaryHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        let api = api
        let perThread = messagesPerThread
        var summaries = [ToolJSON?](repeating: nil, count: ids.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, ToolJSON?).self) { group in
            func start(_ index: Int) throws {
                let id = try GmailAPI.segment(ids[index])
                group.addTask {
                    let thread: ToolJSON
                    do {
                        thread = try await api.get("users/me/threads/\(id)",
                                                   [URLQueryItem(name: "format", value: "metadata")] + headers)
                    } catch GmailAPI.Failure.http(status: 404, _) {
                        return (index, nil)  // deleted between the list and its lookup
                    }
                    let messages = (thread["messages"]?.arrayValue ?? []).map { GmailMessage(json: $0) }
                    let shown = messages.suffix(perThread).map { $0.output(.minimal) }
                    var fields: [String: ToolJSON] = ["id": .string(ids[index]), "messageCount": .integer(Int64(messages.count)),
                                                      "messages": .array(Array(shown))]
                    if messages.count > shown.count { fields["earlierMessagesNotShown"] = .integer(Int64(messages.count - shown.count)) }
                    return (index, .object(fields))
                }
            }
            while next < min(searchConcurrency, ids.count) { try start(next); next += 1 }
            while let (index, summary) = try await group.next() {
                summaries[index] = summary
                if next < ids.count { try start(next); next += 1 }
            }
        }
        return summaries.compactMap { $0 }
    }

    private func format(_ arguments: [String: ToolJSON]) throws -> GmailToolCatalog.Format {
        guard let text = arguments["messageFormat"]?.stringValue, !text.isEmpty, text != "MESSAGE_FORMAT_UNSPECIFIED" else {
            return .plainText
        }
        guard let format = GmailToolCatalog.Format(rawValue: text) else {
            throw ArgumentError.invalid("messageFormat is one of MINIMAL, METADATA_ONLY, PLAIN_TEXT, FULL_CONTENT.")
        }
        return format
    }

    private func formatQuery(_ format: GmailToolCatalog.Format) -> [URLQueryItem] {
        switch format {
        case .plainText, .fullContent:
            [URLQueryItem(name: "format", value: "full")]
        case .minimal, .metadataOnly:
            [URLQueryItem(name: "format", value: "metadata")]
                + (Self.summaryHeaders + ["Bcc"]).map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
    }

    private func getThread(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try GmailAPI.segment(try Self.required(arguments, "threadId"))
        let format = try format(arguments)
        let thread = try await api.get("users/me/threads/\(id)", formatQuery(format))
        let messages = (thread["messages"]?.arrayValue ?? []).map { GmailMessage(json: $0).output(format) }
        return .object(["id": .string(id), "messages": .array(messages)])
    }

    private func getMessage(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try GmailAPI.segment(try Self.required(arguments, "messageId"))
        let format = try format(arguments)
        return GmailMessage(json: try await api.get("users/me/messages/\(id)", formatQuery(format))).output(format)
    }

    private func listLabels() async throws -> ToolJSON {
        let labels = try await api.get("users/me/labels")["labels"]?.arrayValue ?? []
        return .object(["labels": .array(labels.map { label in
            var fields: [String: ToolJSON] = [:]
            for key in ["id", "name", "type"] { if let value = label[key] { fields[key] = value } }
            return .object(fields)
        })])
    }

    // MARK: Writing

    /// The message the fields describe; a reply goes in the replied-to message's thread, to its
    /// Reply-To or sender when no recipient is given, with `Re:` before its subject.
    private func outgoing(_ arguments: [String: ToolJSON]) async throws -> (GmailOutgoingMessage, threadId: String?) {
        var message = GmailOutgoingMessage()
        message.to = try GmailOutgoingMessage.validated(try Self.strings(arguments, "to"))
        message.cc = try GmailOutgoingMessage.validated(try Self.strings(arguments, "cc"))
        message.bcc = try GmailOutgoingMessage.validated(try Self.strings(arguments, "bcc"))
        message.subject = arguments["subject"]?.stringValue ?? ""
        message.body = arguments["body"]?.stringValue
        message.htmlBody = arguments["htmlBody"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        message.attachments = try GmailAttachmentFiles.load(try Self.strings(arguments, "attachments"),
                                                            roots: GmailAttachmentFiles.roots(taskFolders: taskFolders))
        var threadId: String?
        if let reply = arguments["replyToMessageId"]?.stringValue, !reply.isEmpty {
            let id = try GmailAPI.segment(reply)
            let headers = ["Subject", "Message-ID", "References", "From", "Reply-To"]
                .map { URLQueryItem(name: "metadataHeaders", value: $0) }
            let original = GmailMessage(json: try await api.get("users/me/messages/\(id)",
                                                                [URLQueryItem(name: "format", value: "metadata")] + headers))
            threadId = original.threadId
            if let messageID = original.header("Message-ID") {
                message.inReplyTo = messageID
                message.references = [original.header("References"), messageID].compactMap { $0 }.joined(separator: " ")
            }
            if message.subject.isEmpty, let subject = original.header("Subject") {
                message.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
            }
            if !message.hasRecipients, let sender = original.header("Reply-To") ?? original.header("From") {
                message.to = [sender]
            }
        }
        return (message, threadId)
    }

    private func createDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (message, threadId) = try await outgoing(arguments)
        let draft = try await submit(message, threadId: threadId, to: "users/me/drafts") { .object(["message": $0]) }
        var result: [String: ToolJSON] = [:]
        if let id = draft["id"] { result["draftId"] = id }
        if let id = draft["message"]?["id"] { result["messageId"] = id }
        if let thread = draft["message"]?["threadId"] { result["threadId"] = thread }
        if !message.attachments.isEmpty { result["attachments"] = Self.attached(message) }
        return .object(result)
    }

    /// Posts the message as JSON `raw`, or through the upload endpoint when it has attachments:
    /// `wrap` puts the message's fields where the call takes them.
    private func submit(_ message: GmailOutgoingMessage, threadId: String?, to path: String,
                        wrap: (ToolJSON) -> ToolJSON = { $0 }) async throws -> ToolJSON {
        var fields: [String: ToolJSON] = [:]
        if let threadId { fields["threadId"] = .string(threadId) }
        guard !message.attachments.isEmpty else {
            fields["raw"] = .string(message.raw)
            return try await api.post(path, wrap(.object(fields)))
        }
        return try await api.upload(path, metadata: wrap(.object(fields)), message: Data(message.mime.utf8))
    }

    private static func attached(_ message: GmailOutgoingMessage) -> ToolJSON {
        .array(message.attachments.map {
            .object(["filename": .string($0.filename), "mimeType": .string($0.mimeType),
                     "size": .integer(Int64($0.data.count))])
        })
    }

    private func sendDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try GmailAPI.segment(try Self.required(arguments, "draftId"))
        return Self.sent(try await api.post("users/me/drafts/send", .object(["id": .string(id)])))
    }

    private func sendMessage(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (message, threadId) = try await outgoing(arguments)
        guard message.hasRecipients else { throw GmailOutgoingMessage.Problem.noRecipients }
        let sent = Self.sent(try await submit(message, threadId: threadId, to: "users/me/messages/send"))
        guard !message.attachments.isEmpty, var fields = sent.objectValue else { return sent }
        fields["attachments"] = Self.attached(message)
        return .object(fields)
    }

    /// Deletes the draft for good (`drafts.delete`), not to the trash.
    private func deleteDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try await draftID(arguments)
        try await api.delete("users/me/drafts/\(id)")
        return .object(["deleted": .bool(true), "draftId": .string(id)])
    }

    /// What a draft holds, for the request card before it is sent or deleted (`GmailToolApproval`).
    func draftPreview(_ arguments: [String: ToolJSON]) async throws -> MailDraftPreview {
        let full = [URLQueryItem(name: "format", value: "full")]
        if let draft = Self.text(arguments, "draftId") {
            let id = try GmailAPI.segment(draft)
            return MailDraftPreview(GmailMessage(json: try await api.get("users/me/drafts/\(id)", full)["message"] ?? .null))
        }
        let id = try GmailAPI.segment(try Self.required(arguments, "messageId"))
        return MailDraftPreview(GmailMessage(json: try await api.get("users/me/messages/\(id)", full)))
    }

    /// The draft a call names: by its ID, or the draft whose message it gives, found in the
    /// mailbox's drafts a page of 500 at a time.
    private func draftID(_ arguments: [String: ToolJSON]) async throws -> String {
        let draft = Self.text(arguments, "draftId")
        let message = Self.text(arguments, "messageId")
        guard (draft == nil) != (message == nil) else {
            throw ArgumentError.invalid("Give either draftId or messageId, not both.")
        }
        if let draft { return try GmailAPI.segment(draft) }
        let messageID = try GmailAPI.segment(message ?? "")
        var pageToken: String?
        for _ in 0..<20 {
            var query = [URLQueryItem(name: "maxResults", value: "500")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await api.get("users/me/drafts", query)
            if let id = page["drafts"]?.arrayValue?.first(where: { $0["message"]?["id"]?.stringValue == messageID })?["id"]?
                .stringValue {
                return try GmailAPI.segment(id)
            }
            pageToken = page["nextPageToken"]?.stringValue
            if pageToken == nil { break }
        }
        throw ArgumentError.invalid("No draft has the message \(messageID). A draft's message has the DRAFT label.")
    }

    private static func sent(_ message: ToolJSON) -> ToolJSON {
        var result: [String: ToolJSON] = ["sent": .bool(true)]
        if let id = message["id"] { result["messageId"] = id }
        if let thread = message["threadId"] { result["threadId"] = thread }
        if let labels = message["labelIds"] { result["labelIds"] = labels }
        return .object(result)
    }

    private func modifyLabels(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let thread = arguments["threadId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let message = arguments["messageId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard (thread == nil) != (message == nil) else {
            throw ArgumentError.invalid("Give either threadId or messageId, not both.")
        }
        let add = try Self.strings(arguments, "addLabelIds").map(GmailAPI.segment)
        let remove = try Self.strings(arguments, "removeLabelIds").map(GmailAPI.segment)
        guard !add.isEmpty || !remove.isEmpty else {
            throw ArgumentError.invalid("Give at least one label in addLabelIds or removeLabelIds.")
        }
        let body: ToolJSON = .object(["addLabelIds": .array(add.map { .string($0) }),
                                      "removeLabelIds": .array(remove.map { .string($0) })])
        if let thread {
            let id = try GmailAPI.segment(thread)
            let changed = try await api.post("users/me/threads/\(id)/modify", body)
            let messages = (changed["messages"]?.arrayValue ?? []).map {
                ToolJSON.object(["id": $0["id"] ?? .null, "labelIds": $0["labelIds"] ?? .array([])])
            }
            return .object(["threadId": .string(id), "messages": .array(messages)])
        }
        let id = try GmailAPI.segment(message ?? "")
        let changed = try await api.post("users/me/messages/\(id)/modify", body)
        return .object(["messageId": .string(id), "labelIds": changed["labelIds"] ?? .array([])])
    }

    // MARK: Arguments

    private static func text(_ arguments: [String: ToolJSON], _ name: String) -> String? {
        arguments[name]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func required(_ arguments: [String: ToolJSON], _ name: String) throws -> String {
        guard let value = arguments[name]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            throw ArgumentError.missing(name)
        }
        return value
    }

    /// A list of strings; one string alone is taken as a list of one.
    private static func strings(_ arguments: [String: ToolJSON], _ name: String) throws -> [String] {
        switch arguments[name] {
        case nil, .null?: return []
        case .string(let value)?: return value.isEmpty ? [] : [value]
        case .array(let values)?:
            return try values.map {
                guard let text = $0.stringValue else { throw ArgumentError.invalid("\(name) takes strings.") }
                return text
            }
        default: throw ArgumentError.invalid("\(name) takes a list of strings.")
        }
    }

    private static func integer(_ value: ToolJSON?) -> Int? {
        switch value {
        case .integer(let number)?: Int(number)
        case .number(let number)?: Int(number)
        case .string(let text)?: Int(text)
        default: nil
        }
    }
}
