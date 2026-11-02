import Foundation

/// A message the person writes in the mailbox: new, a reply, a reply to all, or a forward. It is kept in
/// memory while it is written and saved only as a draft on the account's service.
struct MailComposition: Equatable, Sendable {
    enum Kind: Hashable, Sendable { case new, reply, replyAll, forward }

    /// One message being written, from its start to its last save.
    let id = UUID()

    var accountID: UUID
    var kind: Kind
    /// The thread a reply or forward belongs to.
    var threadID: String?
    /// The draft on the service, once saved.
    var draftID: String?
    /// The recipients as typed: addresses or `Name <address>`, separated by commas.
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    /// The message a reply answers, for `In-Reply-To` and `References`.
    var inReplyTo: String?
    var references: String?
    /// Local files to attach.
    var attachments: [URL]
    /// The message whose attachments a forward carries.
    var forwardedMessageID: String?

    init(accountID: UUID, kind: Kind = .new, threadID: String? = nil, draftID: String? = nil, to: String = "",
         cc: String = "", bcc: String = "", subject: String = "", body: String = "", inReplyTo: String? = nil,
         references: String? = nil, attachments: [URL] = [], forwardedMessageID: String? = nil) {
        self.accountID = accountID
        self.kind = kind
        self.threadID = threadID
        self.draftID = draftID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.forwardedMessageID = forwardedMessageID
    }

    /// What the person wrote, without where it was saved: what a save compares.
    var content: [String] {
        [accountID.uuidString, to, cc, bcc, subject, body] + attachments.map(\.path)
    }

    /// A reply, a reply to all or a forward of `message`, written from `account`: its recipients and
    /// subject as mail apps set them, and the original quoted under an empty first line.
    static func answering(_ message: MailMessage, in thread: MailThread, as kind: Kind, from account: MailAccount) -> Self {
        let isMe = { (address: MailAddress) in address.address.caseInsensitiveCompare(account.address) == .orderedSame }
        func line(_ addresses: [MailAddress]) -> String {
            var seen: Set<String> = []
            return addresses.filter { !isMe($0) && seen.insert($0.address.lowercased()).inserted }
                .map(Self.formatted).joined(separator: ", ")
        }
        var composition = Self(accountID: account.id, kind: kind, threadID: thread.summary.id.threadID)
        switch kind {
        case .new:
            return composition
        case .reply, .replyAll:
            let sender = message.replyTo.isEmpty ? [message.from] : message.replyTo
            // Replying to one's own message answers the people it went to.
            let primary = isMe(message.from) ? message.to : sender
            composition.to = line(primary)
            if kind == .replyAll {
                let toLine = Set(primary.map { $0.address.lowercased() })
                composition.cc = line((message.to + message.cc).filter { !toLine.contains($0.address.lowercased()) })
            }
            composition.subject = prefixed(message.subject.isEmpty ? thread.summary.subject : message.subject, "Re:")
            composition.inReplyTo = message.messageID
            composition.references = [message.references, message.messageID].compactMap { $0 }.joined(separator: " ")
                .nilIfEmpty
            composition.body = "\n\n" + L10n.format("Mail quote %@ %@", MailText.messageTime(message.date),
                                                    formatted(message.from)) + "\n"
                + message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case .forward:
            composition.subject = prefixed(message.subject.isEmpty ? thread.summary.subject : message.subject, "Fwd:")
            composition.forwardedMessageID = message.id
            var header = ["---------- " + L10n.string("Forwarded message") + " ----------",
                          L10n.format("Mail from %@", formatted(message.from)),
                          L10n.format("Mail date %@", MailText.messageTime(message.date)),
                          L10n.format("Mail subject %@", message.subject),
                          L10n.format("Mail to %@", message.to.map(Self.formatted).joined(separator: ", "))]
            if !message.cc.isEmpty { header.append(L10n.format("Mail cc %@", message.cc.map(Self.formatted).joined(separator: ", "))) }
            composition.body = "\n\n" + header.joined(separator: "\n") + "\n\n" + message.text
        }
        return composition
    }

    /// `Name <address>` as a person reads and types it, the name quoted when it has a comma or another
    /// character that would split it; the address alone without a name.
    static func formatted(_ address: MailAddress) -> String {
        guard let name = address.name else { return address.address }
        guard name.contains(where: { ",;<>@\"".contains($0) }) else { return "\(name) <\(address.address)>" }
        return "\"\(name.replacingOccurrences(of: "\"", with: ""))\" <\(address.address)>"
    }

    /// The subject with `prefix` once: an existing `Re:` or `Fwd:` (any case) is not doubled.
    static func prefixed(_ subject: String, _ prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let known = prefix == "Re:" ? ["re:"] : ["fwd:", "fw:"]
        return known.contains(where: lower.hasPrefix) ? trimmed : "\(prefix) \(trimmed)"
    }

    /// The recipients of one field as the person typed them, split at commas outside quotes and brackets,
    /// as one header line each: `Name <address>`, or the address alone when the name has a character a
    /// header line cannot carry unquoted.
    static func recipients(_ field: String) -> [String] {
        MailAddressList.parse(field).map { address in
            guard let name = address.name, !name.contains(where: { ",;<>@\"".contains($0) }) else { return address.address }
            return "\(name) <\(address.address)>"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
