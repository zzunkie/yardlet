import Foundation
import YardletAgentTools

/// What Claude Code's request card says for a Gmail call that sends, deletes a draft, or changes
/// labels, as the Claude app's Gmail cards say it (2.42304.0 `gmailSendMessage`,
/// `gmailLabelThread`): which account, the recipients, subject, and attachments over the body, or
/// the labels. A draft to send or delete is read from Gmail first, so its card shows what it holds
/// rather than an ID; an Outlook or mail account's draft to send is read and shown the same way
/// (`draftDetail`). Claude Code asks before each such call; the card offers no "always allow", as
/// for a scheduled-task change.
enum GmailToolApproval {
    /// The most attachments a card names one by one.
    static let listedAttachments = 20

    /// The Gmail tool behind a Claude Code name that asks every time, with the account the call acts
    /// in (the one its input names); nil for any other tool.
    static func tool(named claudeToolName: String?, input: JSONValue,
                     labels: ConnectorToolLabels = .shared) -> (tool: String, account: String?)? {
        guard let claudeToolName, let label = labels.label(forClaudeTool: claudeToolName),
              label.localService == .gmail, GmailToolCatalog.approvalRequired.contains(label.tool) else { return nil }
        return (label.tool, label.account(named: input[ConnectorToolNaming.accountArgument]?.stringValue))
    }

    /// Whether the call's card shows a draft read from its mailbox: a Gmail send or delete of one, or
    /// an Outlook or mail account's send of one.
    static func readsDraft(toolName: String?, labels: ConnectorToolLabels = .shared) -> Bool {
        guard let toolName, let label = labels.label(forClaudeTool: toolName) else { return false }
        switch label.localService {
        case .gmail?: return label.tool == GmailToolCatalog.sendDraft || label.tool == GmailToolCatalog.deleteDraft
        case .outlookMail?: return label.tool == OutlookMailToolCatalog.sendDraft
        case .imapMail?: return label.tool == MailAccountToolCatalog.sendDraft
        default: return false
        }
    }

    /// The draft the call names, read from its mailbox within a few seconds; nil when it could not be.
    static func draft(toolName: String?, input: JSONValue, reader: MailDraftReader = .shared) async -> MailDraftPreview? {
        let prefix = "mcp__\(AgentToolEnvironment.serverName)__"
        guard let toolName, toolName.hasPrefix(prefix) else { return nil }
        var arguments: [String: ToolJSON] = [:]
        // The account goes too: a tool its service's accounts share reads the draft from the one the call names.
        for key in ["draftId", "messageId", ConnectorToolNaming.accountArgument] {
            if let value = input[key]?.stringValue, !value.isEmpty { arguments[key] = .string(value) }
        }
        return await reader.read(tool: String(toolName.dropFirst(prefix.count)), arguments: arguments)
    }

    static func request(toolName: String?, input: JSONValue, draft: MailDraftPreview? = nil,
                        labels: ConnectorToolLabels = .shared) -> (title: String, detail: String)? {
        guard let (tool, account) = tool(named: toolName, input: input, labels: labels) else { return nil }
        let mailbox = account ?? "Gmail"
        var lines: [String] = []
        func list(_ key: String) -> [String] {
            switch input[key] {
            case .array(let values)?: values.compactMap(\.stringValue)
            case .string(let value)?: [value]
            default: []
            }
        }
        switch tool {
        case GmailToolCatalog.sendMessage:
            let to = list("to"), cc = list("cc"), bcc = list("bcc")
            if !to.isEmpty { lines.append(L10n.format("To: %@", to.joined(separator: ", "))) }
            if !cc.isEmpty { lines.append(L10n.format("Cc: %@", cc.joined(separator: ", "))) }
            if !bcc.isEmpty { lines.append(L10n.format("Bcc: %@", bcc.joined(separator: ", "))) }
            if let subject = input["subject"]?.stringValue, !subject.isEmpty {
                lines.append(L10n.format("Subject: %@", subject))
            }
            if input["replyToMessageId"]?.stringValue?.isEmpty == false {
                lines.append(L10n.string("Replies in the message's thread."))
            }
            lines += attachmentLines(GmailAttachmentFiles.describe(list("attachments")))
            let body = input["body"]?.stringValue ?? input["htmlBody"]?.stringValue.map(GmailText.plainText(fromHTML:))
            return (L10n.format("Allow Claude to send an email from %@?", mailbox), detail(lines, body))
        case GmailToolCatalog.sendDraft, GmailToolCatalog.deleteDraft:
            let title = tool == GmailToolCatalog.sendDraft
                ? L10n.format("Allow Claude to send a draft from %@?", mailbox)
                : L10n.format("Allow Claude to delete a draft from %@?", mailbox)
            guard let draft else {
                if let id = input["draftId"]?.stringValue, !id.isEmpty {
                    lines.append(L10n.format("Draft %@", id))
                } else if let id = input["messageId"]?.stringValue, !id.isEmpty {
                    lines.append(L10n.format("Message %@", id))
                }
                lines.append(L10n.string("Yardlet could not read this draft from Gmail."))
                return (title, lines.joined(separator: "\n"))
            }
            return (title, draftDetail(draft))
        default:
            if let thread = input["threadId"]?.stringValue, !thread.isEmpty {
                lines.append(L10n.format("Thread %@", thread))
            } else if let message = input["messageId"]?.stringValue, !message.isEmpty {
                lines.append(L10n.format("Message %@", message))
            }
            let add = list("addLabelIds"), remove = list("removeLabelIds")
            if !add.isEmpty { lines.append(L10n.format("Adds: %@", add.joined(separator: ", "))) }
            if !remove.isEmpty { lines.append(L10n.format("Removes: %@", remove.joined(separator: ", "))) }
            if remove.contains("INBOX") { lines.append(L10n.string("Archives it.")) }
            if remove.contains("UNREAD") { lines.append(L10n.string("Marks it read.")) }
            if add.contains("UNREAD") { lines.append(L10n.string("Marks it unread.")) }
            return (L10n.format("Allow Claude to change labels in %@?", mailbox), lines.joined(separator: "\n"))
        }
    }

    /// A draft read before it is sent or deleted: its recipients, subject, when it was saved, and its
    /// files, over its body.
    static func draftDetail(_ draft: MailDraftPreview) -> String {
        var lines: [String] = []
        if let to = draft.to { lines.append(L10n.format("To: %@", to)) }
        if let cc = draft.cc { lines.append(L10n.format("Cc: %@", cc)) }
        if let bcc = draft.bcc { lines.append(L10n.format("Bcc: %@", bcc)) }
        lines.append(L10n.format("Subject: %@", draft.subject ?? L10n.string("(no subject)")))
        if let saved = draft.saved {
            lines.append(L10n.format("Saved: %@", saved.formatted(date: .abbreviated, time: .shortened)))
        }
        lines += attachmentLines(draft.attachments)
        return detail(lines, draft.body)
    }

    /// The lines over the body's first 1,200 characters.
    private static func detail(_ lines: [String], _ body: String?) -> String {
        var detail = lines.joined(separator: "\n")
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            let preview = body.count > 1_200 ? String(body.prefix(1_200)) + "…" : body
            detail += (detail.isEmpty ? "" : "\n\n") + preview
        }
        return detail
    }

    /// "Attachments: 1.4 MB" and a line for each file with its size.
    static func attachmentLines(_ files: [GmailAttachmentFiles.File]) -> [String] {
        guard !files.isEmpty else { return [] }
        func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        var lines = [L10n.format("Attachments: %@", size(files.compactMap(\.size).reduce(0, +)))]
        for file in files.prefix(listedAttachments) {
            lines.append("• " + (file.size.map { "\(file.name) (\(size($0)))" } ?? L10n.format("%@ (not found)", file.name)))
        }
        if files.count > listedAttachments {
            lines.append(L10n.format("…and %lld more", Int64(files.count - listedAttachments)))
        }
        return lines
    }
}

/// A draft as its request card shows it, read from its mailbox before it is sent or deleted.
struct MailDraftPreview: Equatable, Sendable {
    var to: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    var saved: Date?
    var body: String?
    var attachments: [GmailAttachmentFiles.File] = []
}

extension MailDraftPreview {
    init(_ message: GmailMessage) {
        func header(_ name: String) -> String? { message.header(name).flatMap { $0.isEmpty ? nil : $0 } }
        let parts = GmailMessage.parts(message.json["payload"])
        self.init(to: header("To"), cc: header("Cc"), bcc: header("Bcc"), subject: header("Subject"),
                  saved: message.internalDate, body: parts.plain ?? parts.html.map(GmailText.plainText(fromHTML:)),
                  attachments: parts.attachments.map { part in
                      let size: Int? = if case .integer(let bytes)? = part["size"] { Int(bytes) } else { nil }
                      return GmailAttachmentFiles.File(name: part["filename"]?.stringValue ?? "", size: size)
                  })
    }

    /// A draft as the mailbox reads it from Outlook or a mail account.
    init(_ message: MailMessage) {
        func people(_ list: [MailAddress]) -> String? {
            list.isEmpty ? nil : list.map(MailComposition.formatted).joined(separator: ", ")
        }
        self.init(to: people(message.to), cc: people(message.cc), bcc: people(message.bcc),
                  subject: message.subject.isEmpty ? nil : message.subject,
                  saved: message.date == .distantPast ? nil : message.date, body: message.text,
                  attachments: message.attachments.map { GmailAttachmentFiles.File(name: $0.name, size: $0.size) })
    }
}

/// Reads a draft for a request card from an adapter, off the main actor: the connector center
/// sets how, with the mailbox and account behind each Yardlet tool name. A read that takes longer than a few
/// seconds leaves the card without it.
final class MailDraftReader: @unchecked Sendable {
    typealias Read = @Sendable (_ tool: String, _ arguments: [String: ToolJSON]) async -> MailDraftPreview?

    static let shared = MailDraftReader()

    private let lock = NSLock()
    private var reader: Read?
    private let timeout: Duration = .seconds(5)

    func set(_ read: Read?) {
        lock.withLock { reader = read }
    }

    func read(tool: String, arguments: [String: ToolJSON]) async -> MailDraftPreview? {
        guard let read = lock.withLock({ reader }) else { return nil }
        let timeout = timeout
        return await withTaskGroup(of: MailDraftPreview?.self) { group in
            group.addTask { await read(tool, arguments) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
