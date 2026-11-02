import Foundation
@testable import NativeHarnessClient

// Fake mail servers for the IMAP account's tests and renders: they answer commands rather than play a
// transcript, so a message's random Message-ID or a draft's date does not have to be known in advance.

/// A Korean webmail account as the fake IMAP server holds it, shared by its connections: the inbox
/// (two messages, one with a PDF), Sent, Drafts, Spam, Trash and two folders of the person's own, all
/// without special-use attributes; what was appended; and an Archive once made.
final class FakeMailState: @unchecked Sendable {
    private let lock = NSLock()
    private var _inbox = (validity: UInt32(7), next: UInt32(12), messages: 2, unseen: 1)
    private var _appended: [Data] = []
    private var archived = false
    private var _refusesSignIn = false

    var inbox: (validity: UInt32, next: UInt32, messages: Int, unseen: Int) {
        get { lock.withLock { _inbox } }
        set { lock.withLock { _inbox = newValue } }
    }
    var appended: [Data] { lock.withLock { _appended } }
    var refusesSignIn: Bool {
        get { lock.withLock { _refusesSignIn } }
        set { lock.withLock { _refusesSignIn = newValue } }
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
            default: "MESSAGES 0 UNSEEN 0 UIDNEXT \(_appended.count + 1) UIDVALIDITY 9"
            }
            return ("* STATUS \"\(name)\" (\(counts))\r\n", "OK Status completed")
        case #"SELECT "INBOX""#:
            return ("* \(_inbox.messages) EXISTS\r\n* OK [UIDVALIDITY \(_inbox.validity)] UIDs valid\r\n"
                    + "* OK [UIDNEXT \(_inbox.next)] Next\r\n", "OK [READ-WRITE] Select completed")
        case let select where select.hasPrefix("SELECT"):
            return ("* \(_appended.count) EXISTS\r\n* OK [UIDVALIDITY 9] UIDs valid\r\n", "OK [READ-WRITE] Select completed")
        case "FETCH 1:2 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[TEXT]<0.2048>)":
            let first = "내일 회의 자료 보내 드립니다.\r\n"
            let second = "--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nQuote attached\r\n--b1\r\nContent-Type: application/pdf"
            return ("* 1 FETCH (UID 10 FLAGS (\\Seen) INTERNALDATE \"02-Nov-2026 09:00:00 +0900\" RFC822.SIZE 300 ENVELOPE "
                    + "(\"Mon, 2 Nov 2026 09:00:00 +0900\" \"\(Self.subject)\" \(Self.sender) \(Self.sender) \(Self.sender) "
                    + "((NIL NIL \"dana\" \"example.com\")) NIL NIL NIL \"<a1@example.kr>\") BODYSTRUCTURE \(Self.plain) "
                    + "BODY[TEXT]<0> \(Self.literal(first)))\r\n"
                    + "* 2 FETCH (UID 11 FLAGS (\\Flagged) INTERNALDATE \"02-Nov-2026 10:30:00 +0900\" RFC822.SIZE 9000 ENVELOPE "
                    + "(\"Mon, 2 Nov 2026 10:30:00 +0900\" \"Price inside\" ((\"Min\" NIL \"min\" \"example.com\")) NIL NIL "
                    + "((NIL NIL \"dana\" \"example.com\")) NIL NIL NIL \"<b2@example.com>\") BODYSTRUCTURE (\(Self.plain)"
                    + "(\"APPLICATION\" \"PDF\" (\"NAME\" \"quote.pdf\") NIL NIL \"BASE64\" 8000 NIL (\"ATTACHMENT\" "
                    + "(\"FILENAME\" \"quote.pdf\")) NIL NIL) \"MIXED\" (\"BOUNDARY\" \"b1\") NIL NIL NIL) "
                    + "BODY[TEXT]<0> \(Self.literal(second)))\r\n", "OK Fetch completed")
        case "UID FETCH 10 (UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE)":
            return ("* 1 FETCH (UID 10 FLAGS (\\Seen) INTERNALDATE \"02-Nov-2026 09:00:00 +0900\" RFC822.SIZE 300 "
                    + "BODYSTRUCTURE \(Self.plain))\r\n", "OK Fetch completed")
        case "UID FETCH 10 (BODY.PEEK[])":
            return ("* 1 FETCH (UID 10 BODY[] \(Self.literal(Self.raw)))\r\n", "OK Fetch completed")
        case let fetch where fetch.hasPrefix("UID FETCH") && fetch.hasSuffix("(BODY.PEEK[])"):
            let uid = Int(fetch.split(separator: " ")[2]) ?? 0
            let message = String(decoding: _appended[uid - 1], as: UTF8.self)
            return ("* 1 FETCH (UID \(uid) BODY[] \(Self.literal(message)))\r\n", "OK Fetch completed")
        case let append where append.hasPrefix("APPEND"):
            _appended.append(literal ?? Data())
            return ("", "OK [APPENDUID 9 \(_appended.count)] Append completed")
        case #"CREATE "Archive""#:
            archived = true
            return ("", "OK Create completed")
        case let search where search.hasPrefix("UID SEARCH UID"):
            let found = _inbox.next > 13 ? " 13" : ""
            return ("* SEARCH\(found)\r\n", "OK Search completed")
        case let search where search.hasPrefix("UID SEARCH"):
            return ("* SEARCH\r\n", "OK Search completed")
        default:
            return ("", "OK Done")
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

/// An SMTP submission server that takes every command, records them and the message.
final class FakeSMTPServer: MailSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data("220 smtp.example.com ESMTP ready\r\n".utf8)
    private var received = Data()
    private var inData = false
    private var lines: [String] = []
    private var log: [String] = []

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

/// Opens a new fake IMAP or SMTP server for each connection, by the host's name.
final class FakeMailOpener: MailSocketOpening, @unchecked Sendable {
    private let lock = NSLock()
    private let makeIMAP: () -> FakeIMAPServer
    private var imap: [FakeIMAPServer] = []
    private var smtp: [FakeSMTPServer] = []
    private var log: [String] = []

    init(imap: @escaping () -> FakeIMAPServer) {
        makeIMAP = imap
    }

    var imapServers: [FakeIMAPServer] { lock.withLock { imap } }
    var smtpServers: [FakeSMTPServer] { lock.withLock { smtp } }
    var opened: [String] { lock.withLock { log.filter { $0.hasPrefix("imap") } } }

    func open(host: String, port: Int, tls: Bool) async throws -> any MailSocket {
        lock.withLock {
            log.append("\(host):\(port) \(tls ? "tls" : "plain")")
            if host.hasPrefix("smtp") {
                let server = FakeSMTPServer()
                smtp.append(server)
                return server
            }
            let server = makeIMAP()
            imap.append(server)
            return server
        }
    }
}
