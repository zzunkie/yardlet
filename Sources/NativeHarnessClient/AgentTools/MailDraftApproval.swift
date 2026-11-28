import Foundation
import YardletAgentTools

/// Reads and formats draft previews for Outlook and IMAP approval cards.
enum MailDraftApproval {
    /// The most attachments a card names one by one.
    static let listedAttachments = 20

    /// Whether the card previews a draft before sending it.
    static func readsDraft(toolName: String?, labels: ConnectorToolLabels = .shared) -> Bool {
        guard let toolName, let label = labels.label(forClaudeTool: toolName) else { return false }
        switch label.localService {
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
