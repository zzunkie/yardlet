import Foundation

/// A mail account reached over IMAP and SMTP with an app password, behind the mailbox's contract
/// (docs/MAILBOX.md, "Mail accounts over IMAP"). IMAP has no threads, so each message is a thread of
/// one, named by where it is: `<UIDVALIDITY>:<UID>:<folder as the server names it>`. The account's one
/// connection (`IMAPMailSession`) serves the mailbox and the account's agent tools alike.
struct IMAPMailTransport: MailAccountTransport {
    let session: IMAPMailSession
    let account: MailAccount

    func folders() async throws -> [MailFolder] { try await session.folders() }
    func inbox(pageToken: String?) async throws -> MailPage { try await session.inbox(pageToken: pageToken) }
    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage {
        try await session.list(folder.id, pageToken: pageToken)
    }
    func search(_ query: String, pageToken: String?) async throws -> MailPage { try await session.search(query) }
    func thread(_ threadID: String) async throws -> MailThread { try await session.thread(threadID) }
    func change(_ threadID: String, _ change: MailThreadChange) async throws { try await session.change(threadID, change) }
    func saveDraft(_ composition: MailComposition) async throws -> String { try await session.saveDraft(composition) }
    func sendDraft(_ draftID: String) async throws { try await session.sendDraft(draftID) }
    func discardDraft(_ draftID: String) async throws { try await session.discardDraft(draftID) }
    /// A draft is a message of the Drafts folder, so its ID is the message's.
    func draftID(forMessage messageID: String) async throws -> String {
        _ = try IMAPMessageRef.parse(messageID)
        return messageID
    }
    func changeCursor() async throws -> String { try await session.changeCursor() }
    func changes(since cursor: String) async throws -> MailChanges { try await session.changes(since: cursor) }
}

/// A message of an IMAP account: the folder it is in, and its UID there while the folder's UIDVALIDITY
/// stays. A message moved to another folder gets another UID there.
struct IMAPMessageRef: Hashable, Sendable {
    var validity: UInt32
    var uid: UInt32
    /// The folder's name as the server sends it (modified UTF-7).
    var folder: String

    var id: String { "\(validity):\(uid):\(folder)" }

    static func parse(_ id: String) throws -> IMAPMessageRef {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let validity = UInt32(parts[0]), let uid = UInt32(parts[1]), !parts[2].isEmpty else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This message could not be read"))
        }
        return IMAPMessageRef(validity: validity, uid: uid, folder: String(parts[2]))
    }
}

/// One IMAP mail account's connection: signed in on first use with the app password from the secure
/// store, kept open between uses and opened again when the server closed it. Its commands run one
/// sequence at a time, since IMAP reads a folder only after selecting it. Sending signs in to the
/// account's SMTP server for each message.
actor IMAPMailSession {
    nonisolated let id: UUID
    nonisolated let address: String
    nonisolated let settings: MailServerSettings
    private let credentials: any ConnectorCredentialStoring
    private let sockets: any MailSocketOpening
    /// Called when a server refuses the stored password, so the connector shows it needs the account again.
    private let refused: @Sendable () async -> Void
    private let now: @Sendable () -> Date

    private var client: IMAPClient?
    private var selected: String?
    private var lastUsed = Date.distantPast
    private var mailboxes: [IMAPMailbox]?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Messages in a page of a list, as the other services' lists.
    static let pageSize = 50
    /// A message up to this size is read whole when opened; a larger one only its text, its files listed.
    static let wholeMessageLimit = 4 * 1024 * 1024
    /// A connection unused this long is checked with NOOP before it is used: servers close idle ones.
    static let idleCheck: TimeInterval = 120
    /// The newest messages of a folder looked through for one just added there.
    static let recentCount = 20

    private static let listItems = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[TEXT]<0.2048>"

    init(id: UUID, address: String, settings: MailServerSettings, credentials: any ConnectorCredentialStoring,
         sockets: any MailSocketOpening, refused: @escaping @Sendable () async -> Void = {},
         now: @escaping @Sendable () -> Date = Date.init) {
        self.id = id
        self.address = address
        self.settings = settings
        self.credentials = credentials
        self.sockets = sockets
        self.refused = refused
        self.now = now
    }

    /// The connector's address for an account at these servers.
    nonisolated static func address(_ settings: MailServerSettings) -> URL {
        var components = URLComponents()
        components.scheme = "imaps"
        components.host = settings.imapHost
        components.port = settings.imapPort
        return components.url ?? LocalConnectorService.imapMail.address
    }

    /// Signs in to the IMAP and the SMTP server once with `password` and out again; nothing is read or
    /// sent. A refused sign-in throws a `signInRequired` failure with the server's words.
    static func verify(_ settings: MailServerSettings, password: String, sockets: any MailSocketOpening) async throws {
        let imap = IMAPClient(opener: sockets, host: settings.imapHost, port: settings.imapPort, security: settings.imapSecurity,
                              username: settings.imapUsername, password: password)
        do { try await imap.connect() } catch { throw checkFailure(error) }
        await imap.logout()
        do { try await smtp(settings, password: password, sockets: sockets).check() } catch { throw checkFailure(error) }
    }

    /// Whether the account answers: signs in when it is not signed in.
    func check() async throws {
        try await run { _ in }
    }

    func close() async {
        let client = client
        self.client = nil
        selected = nil
        await client?.logout()
    }

    // MARK: Folders

    /// Every folder the account can open: the inbox, the folders for sent mail, drafts, an archive,
    /// spam and the trash, then the person's own folders by name. Unread counts for the inbox and spam,
    /// and how many drafts there are.
    func folders() async throws -> [MailFolder] {
        try await run { client in
            let boxes = try await self.mailboxList(client, fresh: true)
            let roles = Self.roles(boxes)
            var folders: [MailFolder] = []
            for box in boxes where box.isSelectable && !box.attributes.contains("\\all") {
                let role = roles[box.rawName] ?? .label
                let path = Self.path(box)
                var folder = MailFolder(id: box.rawName, name: role == .inbox ? L10n.string("Mail inbox") : path.last ?? box.name,
                                        role: role, depth: role == .label ? max(0, path.count - 1) : 0)
                if [.inbox, .spam, .drafts].contains(role), let status = try? await client.status(box.rawName) {
                    folder.unreadCount = role == .drafts ? status.messages : status.unseen
                }
                folders.append(folder)
            }
            let labelOrder = Dictionary(boxes.map { ($0.rawName, Self.path($0).joined(separator: "\u{0}")) }) { first, _ in first }
            return folders.sorted { lhs, rhs in
                guard lhs.role == rhs.role else { return lhs.role < rhs.role }
                return (labelOrder[lhs.id] ?? lhs.name).localizedStandardCompare(labelOrder[rhs.id] ?? rhs.name) == .orderedAscending
            }
        }
    }

    /// What each folder is for: the inbox by its name, then the server's special-use attributes, then
    /// the names services give them in English and Korean. Each role goes to one folder.
    static func roles(_ boxes: [IMAPMailbox]) -> [String: MailFolderRole] {
        var roles: [String: MailFolderRole] = [:]
        var taken: Set<MailFolderRole> = []
        func assign(_ box: IMAPMailbox, _ role: MailFolderRole?) {
            guard let role, roles[box.rawName] == nil, !taken.contains(role) else { return }
            roles[box.rawName] = role
            taken.insert(role)
        }
        let selectable = boxes.filter(\.isSelectable)
        for box in selectable where box.rawName.caseInsensitiveCompare("INBOX") == .orderedSame { assign(box, .inbox) }
        for box in selectable { assign(box, specialUse(box.attributes)) }
        for box in selectable where Self.path(box).count == 1 { assign(box, namedRoles[box.name.lowercased()]) }
        return roles
    }

    private static func specialUse(_ attributes: Set<String>) -> MailFolderRole? {
        if attributes.contains("\\sent") { return .sent }
        if attributes.contains("\\drafts") { return .drafts }
        if attributes.contains("\\junk") { return .spam }
        if attributes.contains("\\trash") { return .trash }
        if attributes.contains("\\archive") { return .archive }
        if attributes.contains("\\flagged") { return .starred }
        return nil
    }

    private static let namedRoles: [String: MailFolderRole] = {
        var roles: [String: MailFolderRole] = [:]
        for name in ["sent", "sent messages", "sent items", "sent mail", "보낸편지함", "보낸메일함", "보낸 편지함", "보낸 메일함"] {
            roles[name] = .sent
        }
        for name in ["drafts", "draft", "임시보관함", "임시 보관함", "임시저장함"] { roles[name] = .drafts }
        for name in ["spam", "junk", "junk email", "junk e-mail", "bulk mail", "스팸편지함", "스팸메일함", "스팸함", "스팸 편지함"] {
            roles[name] = .spam
        }
        for name in ["trash", "deleted items", "deleted messages", "bin", "휴지통"] { roles[name] = .trash }
        for name in ["archive", "archives", "보관함", "보관 메일함"] { roles[name] = .archive }
        return roles
    }()

    /// A folder's levels as people read them, without the `INBOX.` some servers put every folder under.
    static func path(_ box: IMAPMailbox) -> [String] {
        guard let delimiter = box.delimiter, !delimiter.isEmpty else { return [box.name] }
        var levels = box.name.components(separatedBy: delimiter)
        if levels.count > 1, levels[0].caseInsensitiveCompare("INBOX") == .orderedSame { levels.removeFirst() }
        return levels
    }

    private func mailboxList(_ client: IMAPClient, fresh: Bool = false) async throws -> [IMAPMailbox] {
        if !fresh, let mailboxes { return mailboxes }
        let boxes = try await client.list()
        mailboxes = boxes
        return boxes
    }

    private func folder(_ client: IMAPClient, _ role: MailFolderRole) async throws -> String? {
        Self.roles(try await mailboxList(client)).first { $0.value == role }?.key
    }

    // MARK: Lists

    func inbox(pageToken: String?) async throws -> MailPage {
        try await list(nil, pageToken: pageToken)
    }

    /// A folder's newest messages, a page at a time by their place in the folder: the token is the
    /// folder's UIDVALIDITY and the last place left to read.
    func list(_ folderID: String?, pageToken: String?) async throws -> MailPage {
        try await run { client in
            let raw = try await self.resolved(client, folderID)
            let selection = try await self.select(client, raw, fresh: pageToken == nil)
            guard let validity = selection.uidValidity else { throw IMAPFailure.unexpected("The folder has no UIDVALIDITY.") }
            var end = selection.exists
            if let pageToken {
                let parts = pageToken.split(separator: ":")
                if parts.count == 2, UInt32(parts[0]) == validity, let left = Int(parts[1]) { end = min(left, end) }
            }
            guard end > 0 else { return MailPage(threads: [], nextPageToken: nil) }
            let start = max(1, end - Self.pageSize + 1)
            let fetched = try await client.fetch(sequence: Array(UInt32(start)...UInt32(end)), items: Self.listItems)
            let threads = fetched.compactMap { self.summary($0, folder: raw, validity: validity) }.sorted { $0.date > $1.date }
            return MailPage(threads: threads, nextPageToken: start > 1 ? "\(validity):\(start - 1)" : nil)
        }
    }

    /// The server's own search (`TEXT`, headers and body) in the inbox, the archive and sent mail; the
    /// newest results of all three. A folder where TEXT finds nothing is searched again by subject and
    /// sender, as some servers leave the message out of TEXT. When nothing is found anywhere, the
    /// server is asked to find a message by its number; one that cannot answer that has no search to
    /// offer, which is said rather than shown as no results.
    func search(_ query: String) async throws -> MailPage {
        try await run { client in
            let boxes = try await self.mailboxList(client)
            let roles = Self.roles(boxes)
            let searched = [MailFolderRole.inbox, .archive, .sent].compactMap { role in roles.first { $0.value == role }?.key }
            let term = IMAPClient.quoted(query)
            var threads: [MailThreadSummary] = []
            var answers = false
            for raw in searched {
                let selection = try await self.select(client, raw, fresh: true)
                guard let validity = selection.uidValidity, selection.exists > 0 else { continue }
                var found: [UInt32]
                do { found = try await client.search("TEXT \(term)") } catch IMAPFailure.refused { found = [] }
                if found.isEmpty { found = try await client.search("OR SUBJECT \(term) FROM \(term)") }
                if found.isEmpty, !answers {
                    let last = UInt32(selection.exists)
                    guard try await client.search("\(last)") == [last] else { throw Self.noSearch }
                    answers = true
                }
                // Sequence numbers, read by the FETCH that follows at once, as the folder's list reads them.
                threads += try await client.fetch(sequence: Array(found.sorted().suffix(Self.pageSize)), items: Self.listItems)
                    .compactMap { self.summary($0, folder: raw, validity: validity) }
            }
            return MailPage(threads: Array(threads.sorted { $0.date > $1.date }.prefix(Self.pageSize)), nextPageToken: nil)
        }
    }

    private nonisolated func summary(_ fetch: IMAPFetch, folder: String, validity: UInt32) -> MailThreadSummary? {
        guard let uid = fetch.uid else { return nil }
        let flags = Set(fetch.flags.map { $0.lowercased() })
        let envelope = fetch.envelope
        let structure = fetch.bodyStructure
        let snippet = fetch.sections["TEXT"].map { text in
            MIMESnippet.text(fromPartial: text, transferEncoding: structure?.isMultipart == false ? structure?.encoding : nil,
                             charset: structure?.charset,
                             contentType: structure.map { "\($0.type)/\($0.subtype)" },
                             boundary: structure?.parameters["boundary"])
        } ?? ""
        let ref = IMAPMessageRef(validity: validity, uid: uid, folder: folder)
        return MailThreadSummary(
            id: MailThreadKey(accountID: id, threadID: ref.id),
            subject: MIMEWords.decode(envelope?.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            senders: (envelope?.from ?? []).prefix(1).map(Self.address),
            snippet: snippet,
            date: fetch.internalDate ?? .distantPast,
            messageCount: 1,
            isUnread: !flags.contains("\\seen"),
            isStarred: flags.contains("\\flagged"),
            hasAttachments: structure?.hasAttachments ?? false,
            hasDraft: flags.contains("\\draft"))
    }

    private static func address(_ address: IMAPAddress) -> MailAddress {
        MailAddress(name: address.name.map(MIMEWords.decode), address: address.address)
    }

    // MARK: Reading

    /// One message with its text, HTML and the names of its files. Reading it does not mark it read;
    /// the mailbox does that as a change of its own.
    func thread(_ threadID: String) async throws -> MailThread {
        let ref = try IMAPMessageRef.parse(threadID)
        return try await run { client in
            try await self.open(client, ref)
            guard let head = try await client.fetch(uids: [ref.uid], items: "UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE").first else {
                throw Self.gone
            }
            let flags = Set(head.flags.map { $0.lowercased() })
            let date = head.internalDate ?? .distantPast
            let message: MailMessage
            if (head.size ?? 0) <= Self.wholeMessageLimit {
                let raw = try await client.fetch(uids: [ref.uid], items: "BODY.PEEK[]").first?.sections[""] ?? Data()
                message = Self.message(MIMEMessage.parse(raw), id: threadID, flags: flags, date: date)
            } else {
                message = try await self.largeMessage(client, ref, head: head, flags: flags, date: date)
            }
            let summary = MailThreadSummary(
                id: MailThreadKey(accountID: self.id, threadID: threadID), subject: message.subject, senders: [message.from],
                snippet: message.snippet, date: date, messageCount: 1, isUnread: message.isUnread,
                isStarred: flags.contains("\\flagged"), hasAttachments: !message.attachments.isEmpty, hasDraft: message.isDraft)
            return MailThread(summary: summary, messages: [message], webURL: nil)
        }
    }

    /// A message too large to read whole: its header, its first text and HTML parts, and its files as
    /// BODYSTRUCTURE lists them.
    private func largeMessage(_ client: IMAPClient, _ ref: IMAPMessageRef, head: IMAPFetch, flags: Set<String>,
                              date: Date) async throws -> MailMessage {
        let structure = head.bodyStructure
        let plain = structure?.firstPart(type: "text", subtype: "plain")
        let html = structure?.firstPart(type: "text", subtype: "html")
        var items = ["BODY.PEEK[HEADER]"]
        for part in [plain, html].compactMap({ $0 }) { items.append("BODY.PEEK[\(part.section)]") }
        let fetched = try await client.fetch(uids: [ref.uid], items: items.joined(separator: " ")).first
        func text(_ part: IMAPBodyStructure?) -> String? {
            guard let part, let data = fetched?.sections[part.section] else { return nil }
            let decoded = MIMETransfer.decode([UInt8](data)[...], encoding: part.encoding)
            return MIMECharset.string(Data(decoded), charset: part.charset).replacingOccurrences(of: "\r\n", with: "\n")
        }
        var message = Self.message(MIMEMessage.parse(fetched?.sections["HEADER"] ?? Data()), id: ref.id, flags: flags, date: date)
        message.html = text(html)
        message.text = GmailText.bodyText(plain: text(plain), html: message.html) ?? ""
        message.snippet = Self.snippet(message.text)
        message.attachments = Self.files(structure).enumerated().map { index, part in
            MailAttachment(id: part.section.isEmpty ? "\(index)" : part.section,
                           name: part.filename.map(MIMEWords.decode) ?? L10n.string("Attachment"),
                           size: part.size ?? 0, mimeType: "\(part.type)/\(part.subtype)")
        }
        return message
    }

    private static func files(_ structure: IMAPBodyStructure?) -> [IMAPBodyStructure] {
        guard let structure else { return [] }
        if structure.isMultipart { return structure.parts.flatMap(files) }
        return structure.isAttachment ? [structure] : []
    }

    static func message(_ part: MIMEPart, id: String, flags: Set<String>, date: Date) -> MailMessage {
        func addresses(_ name: String) -> [MailAddress] {
            MailAddressList.parse(part.header(name) ?? "").map { MailAddress(name: $0.name.map(MIMEWords.decode), address: $0.address) }
        }
        let text = part.bodyText
        return MailMessage(
            id: id,
            from: addresses("From").first ?? MailAddress(address: ""),
            to: addresses("To"),
            cc: addresses("Cc"),
            bcc: addresses("Bcc"),
            date: date,
            subject: MIMEWords.decode(part.header("Subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            snippet: snippet(text),
            text: text,
            html: part.html,
            attachments: part.attachments.enumerated().map { index, file in
                MailAttachment(id: "\(index)", name: file.filename ?? L10n.string("Attachment"), size: file.body.count,
                               mimeType: file.contentType)
            },
            isDraft: flags.contains("\\draft"),
            isUnread: !flags.contains("\\seen"),
            messageID: part.header("Message-ID")?.trimmingCharacters(in: .whitespaces),
            references: [part.header("References"), part.header("In-Reply-To")].compactMap { $0 }.first,
            replyTo: addresses("Reply-To"))
    }

    private static func snippet(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(MIMESnippet.limit))
    }

    // MARK: Changes

    /// Read state and the star are flags on the message; Archive moves it to the account's archive,
    /// made the first time when the account has none, as Mail and Thunderbird do; Not spam and Move out
    /// of the Trash move it to the inbox.
    func change(_ threadID: String, _ change: MailThreadChange) async throws {
        let ref = try IMAPMessageRef.parse(threadID)
        let flagChange: Bool = switch change {
        case .read, .starred: true
        case .archived, .notSpam, .untrash: false
        }
        try await run(retrying: flagChange) { client in
            try await self.open(client, ref)
            switch change {
            case let .read(read): try await client.uidStore([ref.uid], adding: read, flags: ["\\Seen"])
            case let .starred(starred): try await client.uidStore([ref.uid], adding: starred, flags: ["\\Flagged"])
            case .archived: try await client.uidMove([ref.uid], to: try await self.archive(client))
            case .notSpam, .untrash:
                guard let inbox = try await self.folder(client, .inbox) else { throw Self.gone }
                try await client.uidMove([ref.uid], to: inbox)
            }
        }
    }

    private func archive(_ client: IMAPClient) async throws -> String {
        if let archive = try await folder(client, .archive) { return archive }
        let inbox = try await mailboxList(client).first { $0.rawName.caseInsensitiveCompare("INBOX") == .orderedSame }
        do {
            try await client.create("Archive")
        } catch IMAPFailure.refused {
            // A server that keeps every folder under the inbox (`INBOX.Archive`).
            guard let delimiter = inbox?.delimiter else { throw IMAPFailure.refused("CREATE Archive") }
            try await client.create("INBOX\(delimiter)Archive")
        }
        mailboxes = nil
        if let archive = try await folder(client, .archive) { return archive }
        guard let archive = try await mailboxList(client).first(where: { Self.path($0).last == "Archive" })?.rawName else {
            throw Self.gone
        }
        return archive
    }

    // MARK: Drafts and sending

    /// Saves what is being written into the account's Drafts as a new message, then deletes the draft it
    /// was saved as before, so a failed save leaves that one. The draft carries its Bcc, which sending
    /// leaves out of what goes to the recipients.
    func saveDraft(_ composition: MailComposition) async throws -> String {
        var message = GmailOutgoingMessage()
        message.from = address
        message.to = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.to))
        message.cc = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.cc))
        message.bcc = try GmailOutgoingMessage.validated(MailComposition.recipients(composition.bcc))
        message.subject = composition.subject
        message.body = composition.body
        message.inReplyTo = composition.inReplyTo
        message.references = composition.references
        message.date = now()
        message.messageID = Self.messageID(for: address)
        message.attachments = try composition.attachments.map { url in
            GmailOutgoingMessage.Attachment(filename: GmailAttachmentFiles.displayName(url.path),
                                            mimeType: FileTypes.mimeType(forExtension: url.pathExtension) ?? "application/octet-stream",
                                            data: try Data(contentsOf: url))
        }
        let earlier = try composition.draftID.map(IMAPMessageRef.parse)
        let messageID = message.messageID ?? ""
        let date = message.date ?? now()
        return try await run(retrying: false) { client in
            var outgoing = message
            if let forwarded = composition.forwardedMessageID { outgoing.attachments += try await self.files(client, of: forwarded) }
            if composition.keepsDraftFiles, let earlier { outgoing.attachments += try await self.files(client, of: earlier.id) }
            let bytes = outgoing.attachments.reduce(0) { $0 + $1.data.count }
            guard bytes <= GmailAttachmentFiles.limit else { throw GmailOutgoingMessage.Problem.attachmentsTooLarge(bytes: bytes) }
            guard let drafts = try await self.folder(client, .drafts) else {
                throw MailFailure(kind: .unavailable, message: L10n.string("This account has no Drafts folder."))
            }
            let appended = try await client.append(drafts, message: Data(outgoing.mime.utf8), flags: ["\\Draft", "\\Seen"], date: date)
            let selection = try await self.select(client, drafts, fresh: true)
            guard let validity = selection.uidValidity else { throw IMAPFailure.unexpected("The folder has no UIDVALIDITY.") }
            // Without UIDPLUS the server does not say the new UID, so the draft is found by its Message-ID.
            var uid = appended
            if uid == nil { uid = try await self.recent(client, selection, messageID: messageID) }
            guard let uid else { throw Self.gone }
            if let earlier {
                try? await self.open(client, earlier)
                try? await client.uidExpunge([earlier.uid])
            }
            return IMAPMessageRef(validity: validity, uid: uid, folder: drafts).id
        }
    }

    /// Sends a draft as it was saved through the account's SMTP server, to its To, Cc and Bcc, with the
    /// Bcc line left out of the message itself; keeps a copy in Sent unless the server put one there,
    /// then deletes the draft. Once the server took the message, what follows does not fail the send.
    func sendDraft(_ draftID: String) async throws {
        let ref = try IMAPMessageRef.parse(draftID)
        try await run(retrying: false) { client in
            try await self.open(client, ref)
            guard let raw = try await client.fetch(uids: [ref.uid], items: "BODY.PEEK[]").first?.sections[""] else { throw Self.gone }
            let part = MIMEMessage.parse(raw)
            let recipients = ["To", "Cc", "Bcc"].flatMap { MailAddressList.parse(part.header($0) ?? "").map(\.address) }
            try await self.smtp().send(message: Self.withoutBcc(raw), from: self.address, recipients: recipients)
            if let sent = try? await self.folder(client, .sent) {
                let messageID = part.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
                var copied = false
                if let messageID, let selection = try? await self.select(client, sent, fresh: true) {
                    copied = (try? await self.recent(client, selection, messageID: messageID)) != nil
                }
                if !copied { _ = try? await client.append(sent, message: raw, flags: ["\\Seen"], date: self.now()) }
            }
            if (try? await self.open(client, ref)) != nil { try? await client.uidExpunge([ref.uid]) }
        }
    }

    func discardDraft(_ draftID: String) async throws {
        let ref = try IMAPMessageRef.parse(draftID)
        try await run(retrying: false) { client in
            try await self.open(client, ref)
            try await client.uidExpunge([ref.uid])
        }
    }

    /// The UID of the message with this Message-ID among the newest few of the open folder, where a
    /// message just added or filed is. Read from their envelopes, as the folder's list reads them: some
    /// servers' search does not find a message by its header.
    private func recent(_ client: IMAPClient, _ selection: IMAPSelection, messageID: String) async throws -> UInt32? {
        guard selection.exists > 0 else { return nil }
        let first = max(1, selection.exists - Self.recentCount + 1)
        return try await client.fetch(sequence: Array(UInt32(first)...UInt32(selection.exists)), items: "UID ENVELOPE")
            .last { $0.envelope?.messageID?.trimmingCharacters(in: .whitespaces) == messageID }?.uid
    }

    /// A message's files with their content, for a forward or a draft edited again.
    private func files(_ client: IMAPClient, of messageID: String) async throws -> [GmailOutgoingMessage.Attachment] {
        let ref = try IMAPMessageRef.parse(messageID)
        try await open(client, ref)
        guard let raw = try await client.fetch(uids: [ref.uid], items: "BODY.PEEK[]").first?.sections[""] else { throw Self.gone }
        return MIMEMessage.parse(raw).attachments.map { file in
            GmailOutgoingMessage.Attachment(filename: file.filename ?? L10n.string("Attachment"), mimeType: file.contentType,
                                            data: file.body)
        }
    }

    /// The message without its Bcc field, which only the envelope carries; the rest byte for byte.
    static func withoutBcc(_ raw: Data) -> Data {
        var kept: [Data] = []
        var inHeader = true
        var skipping = false
        for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if inHeader {
                if line.isEmpty || line.elementsEqual([13]) {
                    inHeader = false
                } else if line.first == UInt8(ascii: " ") || line.first == UInt8(ascii: "\t") {
                    if skipping { continue }
                } else {
                    skipping = String(decoding: line.prefix(4), as: UTF8.self).lowercased() == "bcc:"
                    if skipping { continue }
                }
            }
            kept.append(Data(line))
        }
        return Data(kept.joined(separator: [UInt8(ascii: "\n")]))
    }

    static func messageID(for address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "yardlet.invalid"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    private func smtp() throws -> SMTPClient {
        Self.smtp(settings, password: try password(), sockets: sockets)
    }

    private static func smtp(_ settings: MailServerSettings, password: String, sockets: any MailSocketOpening) -> SMTPClient {
        SMTPClient(opener: sockets, host: settings.smtpHost, port: settings.smtpPort, security: settings.smtpSecurity,
                   username: settings.smtpUsername, password: password)
    }

    // MARK: New mail

    /// The inbox's STATUS: UIDVALIDITY, the next UID, and how many messages and unread ones there are.
    func changeCursor() async throws -> String {
        try await run { client in try await self.cursor(client) }
    }

    /// What changed since `cursor`: nothing while the inbox's counts and next UID stay; unread messages
    /// given UIDs from the cursor's next UID up to the new one, not drafts, as arrived. A new UIDVALIDITY
    /// reads the inbox again and tells nothing.
    func changes(since cursor: String) async throws -> MailChanges {
        try await run { client in
            let current = try await self.cursor(client)
            guard current != cursor else { return MailChanges(cursor: current, changed: false, arrivedThreadIDs: []) }
            let old = cursor.split(separator: ":").compactMap { UInt32($0) }
            let new = current.split(separator: ":").compactMap { UInt32($0) }
            guard old.count == 4, new.count == 4, old[0] == new[0] else {
                return MailChanges(cursor: current, changed: true, arrivedThreadIDs: [])
            }
            var arrived: [String] = []
            if new[1] > old[1], let inbox = try await self.folder(client, .inbox) {
                let selection = try await self.select(client, inbox, fresh: true)
                // New messages are the folder's last, no more of them than UIDs given out since; read with
                // their flags as the list reads messages, since some servers' search does not find them.
                let given = Int(max(selection.uidNext ?? new[1], new[1]) - old[1])
                let count = min(given, Self.pageSize, selection.exists)
                if count > 0 {
                    let tail = Array(UInt32(selection.exists - count + 1)...UInt32(selection.exists))
                    arrived = try await client.fetch(sequence: tail, items: "UID FLAGS").filter { fetch in
                        let flags = Set(fetch.flags.map { $0.lowercased() })
                        return !flags.contains("\\seen") && !flags.contains("\\draft")
                    }
                    .compactMap(\.uid).filter { (old[1]..<new[1]).contains($0) }.sorted()
                    .map { IMAPMessageRef(validity: selection.uidValidity ?? new[0], uid: $0, folder: inbox).id }
                }
            }
            return MailChanges(cursor: current, changed: true, arrivedThreadIDs: arrived)
        }
    }

    private func cursor(_ client: IMAPClient) async throws -> String {
        guard let inbox = try await folder(client, .inbox) else { throw Self.gone }
        let status = try await client.status(inbox)
        return "\(status.uidValidity ?? 0):\(status.uidNext ?? 0):\(status.messages):\(status.unseen)"
    }

    // MARK: Connection

    private static let gone = MailFailure(kind: .unavailable, message: L10n.string("This message is no longer in the account."))
    private static let noSearch = MailFailure(kind: .unavailable,
                                              message: L10n.string("This mail server does not answer searches, so its mail cannot be searched here."))

    /// Runs `work` alone on the connection, signing in first when there is none. A connection the
    /// server closed is opened again, and `work` runs once more when `retrying` says it may: a read, or
    /// a change that is the same however often it is made.
    private func run<T: Sendable>(retrying: Bool = true, _ work: (IMAPClient) async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        do {
            do {
                return try await work(try await connection())
            } catch let failure as MailSocketFailure {
                drop()
                guard retrying else { throw failure }
                return try await work(try await connection())
            }
        } catch {
            if error is MailSocketFailure { drop() }
            throw await mailFailure(error)
        }
    }

    private func connection() async throws -> IMAPClient {
        if let client {
            if now().timeIntervalSince(lastUsed) < Self.idleCheck {
                lastUsed = now()
                return client
            }
            if (try? await client.noop()) != nil {
                lastUsed = now()
                return client
            }
            drop()
        }
        let fresh = IMAPClient(opener: sockets, host: settings.imapHost, port: settings.imapPort, security: settings.imapSecurity,
                               username: settings.imapUsername, password: try password())
        try await fresh.connect()
        client = fresh
        selected = nil
        mailboxes = nil
        lastUsed = now()
        return fresh
    }

    private func drop() {
        client = nil
        selected = nil
    }

    private func password() throws -> String {
        guard let credential = try credentials.load(id), credential.kind == .password, !credential.accessToken.isEmpty else {
            throw IMAPFailure.signInRefused("No app password is stored for the account.")
        }
        return credential.accessToken
    }

    private func resolved(_ client: IMAPClient, _ folderID: String?) async throws -> String {
        if let folderID { return folderID }
        guard let inbox = try await folder(client, .inbox) else { throw Self.gone }
        return inbox
    }

    /// Opens a folder, again when `fresh` so its count is current; the open one otherwise.
    private func select(_ client: IMAPClient, _ raw: String, fresh: Bool = false) async throws -> IMAPSelection {
        if !fresh, selected == raw, let selection = await client.selection { return selection }
        selected = nil
        let selection = try await client.select(raw, readOnly: false)
        selected = raw
        return selection
    }

    /// Opens the folder a message is in, checking that its UIDs still mean what they meant.
    private func open(_ client: IMAPClient, _ ref: IMAPMessageRef) async throws {
        guard try await select(client, ref.folder).uidValidity == ref.validity else { throw Self.gone }
    }

    /// A failure in words the mailbox shows; a refused password also tells the connector.
    private func mailFailure(_ error: Error) async -> Error {
        switch error {
        case IMAPFailure.signInRefused, SMTPFailure.signInRefused:
            drop()
            await refused()
            return MailFailure(kind: .signInRequired, message: L10n.string("The mail server refused the app password."))
        case is MailFailure, is GmailOutgoingMessage.Problem:
            return error
        default:
            return MailFailure(kind: .unavailable, message: error.localizedDescription)
        }
    }

    /// A failure of the setup's check: a refused sign-in in the server's own words, which the setup page
    /// puts in its own sentence.
    private static func checkFailure(_ error: Error) -> MailFailure {
        switch error {
        case let IMAPFailure.signInRefused(text):
            MailFailure(kind: .signInRequired, message: text)
        case let SMTPFailure.signInRefused(code, text):
            MailFailure(kind: .signInRequired, message: "\(code) \(text)")
        default:
            MailFailure(kind: .unavailable, message: error.localizedDescription)
        }
    }
}
