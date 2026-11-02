import Foundation

/// The service a mail account is read through. Each is the way that service supports best: the Gmail API,
/// Microsoft Graph, or IMAP and SMTP for the services that offer nothing else.
enum MailProvider: String, Codable, Hashable, Sendable {
    case gmail
    case outlook
    case imap
}

/// One mailbox shown in the mailbox: an account Yardlet already signs in to for its connectors. `id` is
/// that sign-in's ID (`ConnectorRecord.credentialID`), so the mailbox and the agents' tools share it.
struct MailAccount: Identifiable, Hashable, Sendable {
    let id: UUID
    let address: String
    let provider: MailProvider

    /// The part of the address before the `@`, which tells accounts apart in a list of several.
    var shortName: String {
        address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
    }
}

struct MailAddress: Hashable, Sendable {
    var name: String?
    var address: String

    init(name: String? = nil, address: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
        self.address = address
    }

    /// The name when the message gave one, else the address.
    var displayName: String { name ?? address }
}

/// What a folder is for, as the service marks it: the mailbox orders, names and treats each role alike
/// across services.
enum MailFolderRole: Int, Comparable, Hashable, Sendable {
    case inbox, starred, sent, drafts, archive, spam, trash, label

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Mail the person keeps away: spam, and what they threw out.
    var isSetAside: Bool { self == .spam || self == .trash }
}

/// A folder or label of an account, as its service gives it. Labels may nest (`Clients/Quotes`).
struct MailFolder: Identifiable, Hashable, Sendable {
    /// The service's ID: a Gmail label ID, a Graph folder ID or an IMAP path.
    let id: String
    var name: String
    var role: MailFolderRole
    /// Unread threads, where the service counts them for this folder.
    var unreadCount: Int?
    /// How many levels down a nested label sits.
    var depth: Int = 0
}

/// What the mailbox's list shows: every account's inbox together, or one folder of one account.
enum MailboxSelection: Hashable, Sendable {
    case allInboxes
    case folder(accountID: UUID, folderID: String)

    var accountID: UUID? {
        if case let .folder(accountID, _) = self { return accountID }
        return nil
    }
}

/// A thread across all accounts: the account it belongs to and the service's own thread ID.
struct MailThreadKey: Hashable, Codable, Sendable {
    let accountID: UUID
    let threadID: String
}

/// A line of the mailbox's list: what the service's list answer gives, without bodies.
struct MailThreadSummary: Identifiable, Hashable, Sendable {
    let id: MailThreadKey
    var subject: String
    /// The thread's senders, newest first, each once.
    var senders: [MailAddress]
    var snippet: String
    var date: Date
    var messageCount: Int
    var isUnread: Bool
    var isStarred: Bool
    var hasAttachments: Bool
    /// The thread holds a draft, from the person or an agent.
    var hasDraft: Bool
}

struct MailAttachment: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var size: Int
    var mimeType: String
}

/// One message of an opened thread. Bodies are read only when a thread is opened and kept in memory.
struct MailMessage: Identifiable, Hashable, Sendable {
    let id: String
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var date: Date
    var subject: String
    var snippet: String
    /// The text part, or the HTML part read as text when the message has no text part.
    var text: String
    var html: String?
    var attachments: [MailAttachment]
    var isDraft: Bool
    var isUnread: Bool
    /// The `Message-ID`, `References` and `Reply-To` headers a reply carries on.
    var messageID: String? = nil
    var references: String? = nil
    var replyTo: [MailAddress] = []
}

struct MailThread: Hashable, Sendable {
    var summary: MailThreadSummary
    /// Oldest first, drafts where the service keeps them.
    var messages: [MailMessage]
    /// The thread on the service's own web mail.
    var webURL: URL?
}

/// One page of a list or a search.
struct MailPage: Sendable {
    var threads: [MailThreadSummary]
    var nextPageToken: String?
}

/// What changes the mailbox makes to a thread on the service.
enum MailThreadChange: Hashable, Sendable {
    case read(Bool)
    case starred(Bool)
    /// Out of the inbox, kept in the account.
    case archived
    /// Out of spam, into the inbox.
    case notSpam
    /// Out of the trash, back where it was.
    case untrash
}

/// What changed in an account after a cursor (`MailAccountTransport.changes(since:)`).
struct MailChanges: Equatable, Sendable {
    /// Where to ask from next time.
    var cursor: String
    /// Whether the inbox changed at all, so its list is read again.
    var changed: Bool
    /// Threads with a message that came into the inbox unread and is worth telling the person about:
    /// for Gmail, one in the Primary category.
    var arrivedThreadIDs: [String]
}

/// Why a mailbox could not be read, in words the mailbox shows.
struct MailFailure: Error, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case signInRequired
        case unavailable
    }

    var kind: Kind
    var message: String
}

/// How the mailbox reaches one account's service. Each provider has one: the Gmail API, Microsoft Graph,
/// IMAP and SMTP. It reads only what the person looks at and changes only what the person asks.
protocol MailAccountTransport: Sendable {
    /// The account's folders and labels: its inbox first, then the service's other folders by role,
    /// then its labels by name.
    func folders() async throws -> [MailFolder]
    /// The inbox, newest first.
    func inbox(pageToken: String?) async throws -> MailPage
    /// One folder, newest first.
    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage
    /// The service's own search over the whole account, in the query language it takes.
    func search(_ query: String, pageToken: String?) async throws -> MailPage
    func thread(_ threadID: String) async throws -> MailThread
    func change(_ threadID: String, _ change: MailThreadChange) async throws
    /// Saves what the person is writing as a draft on the service, new or over the draft it was saved as
    /// before, and returns the draft's ID.
    func saveDraft(_ composition: MailComposition) async throws -> String
    /// Sends a saved draft; the service keeps it in Sent, in its thread.
    func sendDraft(_ draftID: String) async throws
    func discardDraft(_ draftID: String) async throws
    /// The draft a thread's draft message is, to open, send or discard it.
    func draftID(forMessage messageID: String) async throws -> String
    /// Where the account's history stands now, to ask what changed after it.
    func changeCursor() async throws -> String
    /// What changed in the inbox after `cursor`. A cursor the service no longer knows comes back as a
    /// change with a fresh cursor and nothing arrived, so the inbox is read again.
    func changes(since cursor: String) async throws -> MailChanges
}

/// Whether opening a thread in the mailbox marks it read on the service too, as mail apps do. Messages an
/// agent reads through its tools stay as they are.
enum MailReadSync {
    static let marksOpenedThreadsRead = true
}

/// Addresses from a `From`, `To` or `Cc` header as Gmail gives it (decoded): `Name <a@b>`,
/// `"Last, First" <a@b>` or a bare `a@b`, separated by commas outside quotes and angle brackets.
enum MailAddressList {
    static func parse(_ header: String) -> [MailAddress] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var escaped = false
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inQuotes: escaped = true; continue
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            case "," where !inQuotes && !inAngle, ";" where !inQuotes && !inAngle:
                entries.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        entries.append(current)
        return entries.compactMap(address)
    }

    private static func address(_ entry: String) -> MailAddress? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        // A group's name ("Team: a@b") stays out of the address.
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("<"), !text[..<colon].contains("@") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard address.contains("@") else { return nil }
            let name = text[..<open].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return MailAddress(name: name, address: address)
        }
        guard text.contains("@"), !text.contains(" ") else { return nil }
        return MailAddress(address: text)
    }
}
