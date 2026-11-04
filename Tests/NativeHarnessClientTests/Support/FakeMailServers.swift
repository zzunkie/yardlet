import Foundation
@testable import NativeHarnessClient

// Fake mail servers for the IMAP account's tests and renders: they answer commands rather than play a
// transcript, so a message's random Message-ID or a draft's date does not have to be known in advance.

/// A Korean webmail account as the fake IMAP server holds it, shared by its connections: the inbox
/// (two messages, one with a PDF, and the unread ones that arrive after them), Sent, Drafts, Spam, Trash
/// and two folders of the person's own, all without special-use attributes; the messages appended to a
/// folder, read back as drafts by their UID, and copies of sent mail when the server files them itself;
/// and an Archive once made. Its search leaves messages out of TEXT, as some servers' does, but finds
/// them by subject.
final class FakeMailState: @unchecked Sendable {
    private let lock = NSLock()
    private var _inbox = (validity: UInt32(7), next: UInt32(12), messages: 2, unseen: 1)
    /// Messages outside the inbox by folder; a message's UID is its place in this list, from 1.
    private var messages: [(folder: String, data: Data, appended: Bool)] = []
    private var selected = ""
    private var archived = false
    private var _refusesSignIn = false
    private var _filesSentCopies = false
    private var _searchesNothing = false

    var inbox: (validity: UInt32, next: UInt32, messages: Int, unseen: Int) {
        get { lock.withLock { _inbox } }
        set { lock.withLock { _inbox = newValue } }
    }
    /// What the client appended, to any folder.
    var appended: [Data] { lock.withLock { messages.filter(\.appended).map(\.data) } }
    var refusesSignIn: Bool {
        get { lock.withLock { _refusesSignIn } }
        set { lock.withLock { _refusesSignIn = newValue } }
    }
    /// Whether the server files a copy of what it sends in Sent, as webmail services do.
    var filesSentCopies: Bool {
        get { lock.withLock { _filesSentCopies } }
        set { lock.withLock { _filesSentCopies = newValue } }
    }
    /// Whether every SEARCH comes back without a number, as from a server whose search does not work.
    var searchesNothing: Bool {
        get { lock.withLock { _searchesNothing } }
        set { lock.withLock { _searchesNothing = newValue } }
    }

    func folder(_ name: String) -> [Data] {
        lock.withLock { messages.filter { $0.folder == name }.map(\.data) }
    }

    /// The SMTP server took `message`; the server files it in Sent when it does that.
    func sent(_ message: Data) {
        lock.withLock {
            if _filesSentCopies { messages.append((Self.sentName, message, false)) }
        }
    }

    private static let subject = "=?UTF-8?B?7ZqM7J2YIOyekOujjA==?="
    private static let sender = #"(("=?UTF-8?B?6rmA7LKg7IiY?=" NIL "chulsoo" "example.kr"))"#
    private static let plain = #"("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "8BIT" 48 1 NIL NIL NIL NIL)"#
    private static let raw = [
        "From: =?UTF-8?B?6rmA7LKg7IiY?= <chulsoo@example.kr>", "To: dana@example.com", "Subject: \(subject)",
        "Date: Mon, 2 Nov 2026 09:00:00 +0900", "Message-ID: <a1@example.kr>", "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: 8bit", "", "내일 회의 자료 보내 드립니다.", "",
    ].joined(separator: "\r\n")

    func answer(_ command: String, _ literal: Data?) -> (untagged: String, status: String) {
        lock.withLock { respond(command, literal) }
    }

    private func respond(_ command: String, _ literal: Data?) -> (untagged: String, status: String) {
        switch command {
        case let auth where auth.hasPrefix("AUTHENTICATE PLAIN"):
            return _refusesSignIn ? ("", "NO [AUTHENTICATIONFAILED] Invalid credentials")
                : ("", "OK [CAPABILITY IMAP4rev1 UIDPLUS MOVE] Signed in")
        case #"LIST "" "*""#:
            var names = ["INBOX", FakeMailState.sentName, FakeMailState.draftsName, "&wqTTONO4ycDVaA-", "&1zTJwNG1-",
                         "&rHC3mMyY-", "&rHC3mMyY-/2026"]
            if archived { names.append("Archive") }
            return (names.map { #"* LIST (\HasNoChildren) "/" "\#($0)""# + "\r\n" }.joined(), "OK List completed")
        case let status where status.hasPrefix("STATUS"):
            let name = status.split(separator: "\"")[1]
            let counts = switch name {
            case "INBOX": "MESSAGES \(_inbox.messages) UNSEEN \(_inbox.unseen) UIDNEXT \(_inbox.next) UIDVALIDITY \(_inbox.validity)"
            case "&wqTTONO4ycDVaA-": "MESSAGES 3 UNSEEN 3 UIDNEXT 4 UIDVALIDITY 8"
            default: "MESSAGES 0 UNSEEN 0 UIDNEXT \(messages.count + 1) UIDVALIDITY 9"
            }
            return ("* STATUS \"\(name)\" (\(counts))\r\n", "OK Status completed")
        case #"SELECT "INBOX""#:
            selected = "INBOX"
            return ("* \(_inbox.messages) EXISTS\r\n* OK [UIDVALIDITY \(_inbox.validity)] UIDs valid\r\n"
                    + "* OK [UIDNEXT \(_inbox.next)] Next\r\n", "OK [READ-WRITE] Select completed")
        case let select where select.hasPrefix("SELECT"):
            selected = String(select.split(separator: "\"")[1])
            return ("* \(messages.filter { $0.folder == selected }.count) EXISTS\r\n* OK [UIDVALIDITY 9] UIDs valid\r\n",
                    "OK [READ-WRITE] Select completed")
        case let fetch where fetch.hasPrefix("FETCH ") && fetch.hasSuffix(" \(Self.listItems)"):
            return (Self.numbers(fetch.split(separator: " ")[1]).compactMap(Self.listed).joined(), "OK Fetch completed")
        case let fetch where fetch.hasPrefix("FETCH ") && fetch.hasSuffix(" (UID FLAGS)") && selected == "INBOX":
            // The inbox's messages after the two listed: UID 12 already read elsewhere, UID 13 unread.
            let flags: [UInt32: String] = [10: #"\Seen"#, 11: #"\Flagged"#, 12: #"\Seen"#]
            return (Self.numbers(fetch.split(separator: " ")[1]).map { sequence in
                let uid = UInt32(9 + sequence)
                return "* \(sequence) FETCH (UID \(uid) FLAGS (\(flags[uid] ?? "")))\r\n"
            }.joined(), "OK Fetch completed")
        case let fetch where fetch.hasPrefix("FETCH ") && fetch.hasSuffix(" (UID ENVELOPE)"):
            let here = messages.indices.filter { messages[$0].folder == selected }
            return (Self.numbers(fetch.split(separator: " ")[1]).compactMap { sequence in
                guard sequence <= here.count else { return nil }
                let index = here[sequence - 1]
                let id = String(decoding: messages[index].data, as: UTF8.self).components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("Message-ID: ") }?.dropFirst(12) ?? ""
                return "* \(sequence) FETCH (UID \(index + 1) ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL \"\(id)\"))\r\n"
            }.joined(), "OK Fetch completed")
        case "UID FETCH 10 (UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE)":
            return ("* 1 FETCH (UID 10 FLAGS (\\Seen) INTERNALDATE \"02-Nov-2026 09:00:00 +0900\" RFC822.SIZE 300 "
                    + "BODYSTRUCTURE \(Self.plain))\r\n", "OK Fetch completed")
        case "UID FETCH 10 (BODY.PEEK[])":
            return ("* 1 FETCH (UID 10 BODY[] \(Self.literal(Self.raw)))\r\n", "OK Fetch completed")
        case let fetch where fetch.hasPrefix("UID FETCH") && fetch.hasSuffix("(UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE)"):
            let uid = Int(fetch.split(separator: " ")[2]) ?? 0
            guard messages.indices.contains(uid - 1) else { return ("", "OK Fetch completed") }
            return ("* 1 FETCH (UID \(uid) FLAGS (\\Draft \\Seen) INTERNALDATE \"02-Nov-2026 12:00:00 +0000\" "
                    + "RFC822.SIZE \(messages[uid - 1].data.count))\r\n", "OK Fetch completed")
        case let fetch where fetch.hasPrefix("UID FETCH") && fetch.hasSuffix("(BODY.PEEK[])"):
            let uid = Int(fetch.split(separator: " ")[2]) ?? 0
            let message = String(decoding: messages[uid - 1].data, as: UTF8.self)
            return ("* 1 FETCH (UID \(uid) BODY[] \(Self.literal(message)))\r\n", "OK Fetch completed")
        case let append where append.hasPrefix("APPEND"):
            messages.append((String(append.split(separator: "\"")[1]), literal ?? Data(), true))
            return ("", "OK [APPENDUID 9 \(messages.count)] Append completed")
        case #"CREATE "Archive""#:
            archived = true
            return ("", "OK Create completed")
        case let search where search.hasPrefix("SEARCH "):
            let criteria = search.dropFirst(7)
            let found: [Int] = switch criteria {
            case _ where _searchesNothing: []
            case #"OR SUBJECT "Price" FROM "Price""#: [2]
            case let number where Int(number) != nil: [Int(number) ?? 0]
            default: []
            }
            return ("* SEARCH\(found.map { " \($0)" }.joined())\r\n", "OK Search completed")
        default:
            return ("", "OK Done")
        }
    }

    private static let listItems = "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[TEXT]<0.2048>)"

    /// The list's FETCH response for an inbox message by its place: the meeting notes, and the quote
    /// with its PDF.
    private static func listed(_ sequence: Int) -> String? {
        switch sequence {
        case 1:
            "* 1 FETCH (UID 10 FLAGS (\\Seen) INTERNALDATE \"02-Nov-2026 09:00:00 +0900\" RFC822.SIZE 300 ENVELOPE "
                + "(\"Mon, 2 Nov 2026 09:00:00 +0900\" \"\(subject)\" \(sender) \(sender) \(sender) "
                + "((NIL NIL \"dana\" \"example.com\")) NIL NIL NIL \"<a1@example.kr>\") BODYSTRUCTURE \(plain) "
                + "BODY[TEXT]<0> \(literal("내일 회의 자료 보내 드립니다.\r\n")))\r\n"
        case 2:
            "* 2 FETCH (UID 11 FLAGS (\\Flagged) INTERNALDATE \"02-Nov-2026 10:30:00 +0900\" RFC822.SIZE 9000 ENVELOPE "
                + "(\"Mon, 2 Nov 2026 10:30:00 +0900\" \"Price inside\" ((\"Min\" NIL \"min\" \"example.com\")) NIL NIL "
                + "((NIL NIL \"dana\" \"example.com\")) NIL NIL NIL \"<b2@example.com>\") BODYSTRUCTURE (\(plain)"
                + "(\"APPLICATION\" \"PDF\" (\"NAME\" \"quote.pdf\") NIL NIL \"BASE64\" 8000 NIL (\"ATTACHMENT\" "
                + "(\"FILENAME\" \"quote.pdf\")) NIL NIL) \"MIXED\" (\"BOUNDARY\" \"b1\") NIL NIL NIL) "
                + "BODY[TEXT]<0> \(literal(quoteText)))\r\n"
        default: nil
        }
    }

    private static let quoteText = "--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nQuote attached\r\n--b1\r\nContent-Type: application/pdf"

    /// The numbers of a sequence set such as `3:4` or `2,5`.
    private static func numbers(_ set: Substring) -> [Int] {
        set.split(separator: ",").flatMap { run -> [Int] in
            let ends = run.split(separator: ":").compactMap { Int($0) }
            guard let first = ends.first, let last = ends.last else { return [] }
            return Array(first...last)
        }
    }

    static let draftsName = "&x4TC3Lz0rQDVaA-"
    static let sentName = "&vPSwuNO4ycDVaA-"

    private static func literal(_ text: String) -> String {
        "{\(text.utf8.count)}\r\n\(text)"
    }
}

/// An IMAP server that answers each command through `answer` (the command without its tag, any literal
/// it carried as `{literal}`) and records the commands. A literal gets the continuation first.
final class FakeIMAPServer: MailSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: (String, Data?) -> (untagged: String, status: String)
    private var pending: Data
    private var received = Data()
    private var waiting: (command: String, size: Int)?
    private var afterLiteral: (command: String, data: Data)?
    private var log: [String] = []

    init(answer: @escaping (String, Data?) -> (untagged: String, status: String)) {
        self.answer = answer
        pending = Data("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] Ready\r\n".utf8)
    }

    var commands: [String] { lock.withLock { log } }

    func read() async throws -> Data {
        lock.withLock {
            defer { pending = Data() }
            return pending
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            received.append(data)
            process()
        }
    }

    func startTLS() async throws {}
    func close() {}

    private func process() {
        while true {
            if let literal = waiting {
                guard received.count >= literal.size else { return }
                afterLiteral = (literal.command, Data(received.prefix(literal.size)))
                received = Data(received.dropFirst(literal.size))
                waiting = nil
                continue
            }
            guard let end = received.range(of: Data([13, 10])) else { return }
            let line = String(decoding: received[..<end.lowerBound], as: UTF8.self)
            received = Data(received[end.upperBound...])
            if let after = afterLiteral {
                afterLiteral = nil
                respond(after.command + "{literal}" + line, after.data)
            } else if let size = line.range(of: #"\{\d+\}$"#, options: .regularExpression) {
                waiting = (String(line[..<size.lowerBound]), Int(line[size].dropFirst().dropLast()) ?? 0)
                pending.append(Data("+ Ready for literal data\r\n".utf8))
            } else {
                respond(line, nil)
            }
        }
    }

    private func respond(_ line: String, _ literal: Data?) {
        let parts = line.split(separator: " ", maxSplits: 1)
        let tag = String(parts[0])
        let command = parts.count > 1 ? String(parts[1]) : ""
        log.append(command)
        switch command {
        case "LOGOUT": pending.append(Data("* BYE Logging out\r\n\(tag) OK Logout completed\r\n".utf8))
        case "NOOP": pending.append(Data("\(tag) OK Noop completed\r\n".utf8))
        default:
            let (untagged, status) = answer(command, literal)
            pending.append(Data((untagged + "\(tag) \(status)\r\n").utf8))
        }
    }
}

/// An SMTP submission server that takes every command, records them and the message, and hands the
/// message to `delivered` once it is taken.
final class FakeSMTPServer: MailSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let delivered: @Sendable (Data) -> Void
    private var pending = Data("220 smtp.example.com ESMTP ready\r\n".utf8)
    private var received = Data()
    private var inData = false
    private var lines: [String] = []
    private var log: [String] = []

    init(delivered: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.delivered = delivered
    }

    var commands: [String] { lock.withLock { log } }
    var message: String { lock.withLock { lines.joined(separator: "\n") } }

    func read() async throws -> Data {
        lock.withLock {
            defer { pending = Data() }
            return pending
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            received.append(data)
            while let end = received.range(of: Data([13, 10])) {
                let line = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                received = Data(received[end.upperBound...])
                if inData {
                    if line == "." {
                        inData = false
                        delivered(Data(lines.joined(separator: "\r\n").utf8))
                        pending.append(Data("250 2.0.0 Ok: queued\r\n".utf8))
                    } else {
                        lines.append(line)
                    }
                    continue
                }
                log.append(line)
                let reply = switch line.split(separator: " ").first.map(String.init) ?? "" {
                case "EHLO": "250-smtp.example.com\r\n250 AUTH PLAIN LOGIN"
                case "AUTH": "235 2.7.0 Authentication successful"
                case "DATA": "354 End data with <CR><LF>.<CR><LF>"
                case "QUIT": "221 2.0.0 Bye"
                default: "250 2.1.0 Ok"
                }
                if line == "DATA" { inData = true }
                pending.append(Data((reply + "\r\n").utf8))
            }
        }
    }

    func startTLS() async throws {}
    func close() {}
}

/// Opens a new fake IMAP or SMTP server for each connection, by the host's name; what an SMTP server
/// takes goes to `sent`.
final class FakeMailOpener: MailSocketOpening, @unchecked Sendable {
    private let lock = NSLock()
    private let makeIMAP: () -> FakeIMAPServer
    private let sent: @Sendable (Data) -> Void
    private var imap: [FakeIMAPServer] = []
    private var smtp: [FakeSMTPServer] = []
    private var log: [String] = []

    init(imap: @escaping () -> FakeIMAPServer, sent: @escaping @Sendable (Data) -> Void = { _ in }) {
        makeIMAP = imap
        self.sent = sent
    }

    var imapServers: [FakeIMAPServer] { lock.withLock { imap } }
    var smtpServers: [FakeSMTPServer] { lock.withLock { smtp } }
    var opened: [String] { lock.withLock { log.filter { $0.hasPrefix("imap") } } }

    func open(host: String, port: Int, tls: Bool) async throws -> any MailSocket {
        lock.withLock {
            log.append("\(host):\(port) \(tls ? "tls" : "plain")")
            if host.hasPrefix("smtp") {
                let server = FakeSMTPServer(delivered: sent)
                smtp.append(server)
                return server
            }
            let server = makeIMAP()
            imap.append(server)
            return server
        }
    }
}
