import Foundation

/// Why an IMAP command did not succeed, in the server's own words. The account's password never
/// appears in it, even when a server repeats the command back.
enum IMAPFailure: Error, Equatable, LocalizedError {
    /// The server answered NO or BAD: its text, the response code in brackets included
    /// (`[TRYCREATE] Mailbox doesn't exist`).
    case refused(String)
    /// The server turned down the account's name and password.
    case signInRefused(String)
    /// The server lacks what the client needs: STARTTLS on a connection that starts plain, or a way to
    /// sign in with a password.
    case missingCapability(String)
    /// The server sent something the client could not read or did not expect.
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case let .refused(text): "The mail server refused the request: \(text)"
        case let .signInRefused(text): "The mail server did not accept the name and password: \(text)"
        case let .missingCapability(name): "The mail server does not offer \(name)."
        case let .unexpected(text): "The mail server sent a reply that could not be read: \(text)"
        }
    }
}

/// An IMAP connection to one account (RFC 9051, and RFC 3501, which most services still speak), for the
/// services the mailbox reads without an API of their own. It signs in only over TLS, sends one command
/// at a time, and reads the server's bytes however the socket splits them.
///
/// A failure other than the server's NO or BAD leaves the connection in an unknown state, so the client
/// closes it; the next command then fails with `MailSocketFailure.closed` until `connect()` is called
/// again.
actor IMAPClient {
    private let opener: any MailSocketOpening
    private let host: String
    private let port: Int
    private let security: MailSocketSecurity
    private let username: String
    private let password: String

    /// What the server advertises, uppercased (`IMAP4REV1`, `MOVE`, `AUTH=PLAIN`); read again after
    /// STARTTLS and after signing in, since both change it.
    private(set) var capabilities: Set<String> = []
    /// The folder SELECT or EXAMINE opened last, its count kept current from the server's EXISTS and
    /// EXPUNGE responses.
    private(set) var selection: IMAPSelection?

    private var socket: (any MailSocket)?
    private var isTLS = false
    private var buffer = MailReadBuffer()
    private var nextTag = 1
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(opener: any MailSocketOpening, host: String, port: Int, security: MailSocketSecurity,
         username: String, password: String) {
        self.opener = opener
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
    }

    // MARK: Commands

    /// Connects, starts TLS when the connection starts plain, and signs in: AUTHENTICATE PLAIN where the
    /// server offers it, LOGIN otherwise. An open connection is closed first.
    func connect() async throws {
        await acquire()
        defer { release() }
        drop()
        let socket = try await opener.open(host: host, port: port, tls: security == .tls)
        self.socket = socket
        isTLS = security == .tls
        nextTag = 1
        do {
            try await openSession(socket)
        } catch {
            drop()
            throw error
        }
    }

    /// Every folder: `LIST "" "*"`, with the special-use attributes (`\Sent`, `\Trash`) where the server
    /// offers them.
    func list() async throws -> [IMAPMailbox] {
        await acquire()
        defer { release() }
        let options = capabilities.contains("SPECIAL-USE") ? " RETURN (SPECIAL-USE)" : ""
        var mailboxes: [IMAPMailbox] = []
        for case let .list(mailbox) in try await run("LIST \"\" \"*\"\(options)").untagged {
            mailboxes.append(mailbox)
        }
        return mailboxes
    }

    func status(_ rawName: String) async throws -> IMAPStatus {
        await acquire()
        defer { release() }
        var statuses: [(name: String, status: IMAPStatus)] = []
        for case let .status(name, status) in try await run("STATUS \(Self.quoted(rawName)) (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)").untagged {
            statuses.append((name, status))
        }
        guard let status = statuses.first(where: { $0.name == rawName })?.status ?? statuses.last?.status else {
            throw IMAPFailure.unexpected("The server gave no STATUS for the folder.")
        }
        return status
    }

    /// Makes a folder, as other mail apps make an Archive folder the first time a message is archived on
    /// a server without one. A folder that already exists (`[ALREADYEXISTS]`, RFC 5530) is no failure.
    func create(_ rawName: String) async throws {
        await acquire()
        defer { release() }
        do {
            try await run("CREATE \(Self.quoted(rawName))")
        } catch let IMAPFailure.refused(text) where text.uppercased().hasPrefix("[ALREADYEXISTS]") {
            return
        }
    }

    /// Opens a folder: SELECT, or EXAMINE when `readOnly`, which leaves flags and \Recent alone.
    func select(_ rawName: String, readOnly: Bool) async throws -> IMAPSelection {
        await acquire()
        defer { release() }
        // A failed SELECT leaves no folder open (RFC 9051, section 6.3.2).
        selection = nil
        let completion = try await run("\(readOnly ? "EXAMINE" : "SELECT") \(Self.quoted(rawName))")
        var opened = IMAPSelection(exists: 0)
        for response in completion.untagged {
            switch response {
            case let .exists(count): opened.exists = count
            case let .condition(condition) where condition.code == "UIDVALIDITY":
                opened.uidValidity = condition.codeArguments.first?.number32
            case let .condition(condition) where condition.code == "UIDNEXT":
                opened.uidNext = condition.codeArguments.first?.number32
            default: break
            }
        }
        selection = opened
        return opened
    }

    /// FETCH for a range of sequence numbers, or UID FETCH for `uids` when given; all messages when
    /// neither is. `items` are FETCH's data items as IMAP writes them (`UID FLAGS ENVELOPE`,
    /// `BODY.PEEK[1]<0.2048>`). Responses for one message are merged, and unsolicited ones for messages
    /// the command did not name are left out.
    func fetch(sequence: ClosedRange<UInt32>? = nil, uids: [UInt32]? = nil, items: String) async throws -> [IMAPFetch] {
        await acquire()
        defer { release() }
        let command: String
        let wanted: (IMAPFetch) -> Bool
        if let uids {
            guard !uids.isEmpty else { return [] }
            let set = Set(uids)
            command = "UID FETCH \(Self.sequenceSet(uids))"
            wanted = { $0.uid.map(set.contains) ?? false }
        } else if let sequence {
            command = "FETCH \(sequence.lowerBound):\(sequence.upperBound)"
            wanted = { sequence.contains($0.sequence) }
        } else {
            command = "FETCH 1:*"
            wanted = { _ in true }
        }
        let list = items.hasPrefix("(") ? items : "(\(items))"
        var order: [UInt32] = []
        var fetched: [UInt32: IMAPFetch] = [:]
        for case let .fetch(fetch) in try await run("\(command) \(list)").untagged {
            if fetched[fetch.sequence] == nil {
                order.append(fetch.sequence)
                fetched[fetch.sequence] = fetch
            } else {
                fetched[fetch.sequence]?.merge(fetch)
            }
        }
        return order.compactMap { fetched[$0] }.filter(wanted)
    }

    /// UID SEARCH with `criteria` as IMAP writes them (`UNSEEN SINCE 1-Nov-2026`). Put strings in with
    /// `quoted(_:)`: one that is not ASCII is sent as a literal, under `CHARSET UTF-8` unless `charset`
    /// names another.
    func uidSearch(_ criteria: String, charset: String? = nil) async throws -> [UInt32] {
        await acquire()
        defer { release() }
        let parts = Self.parts(criteria)
        var command = "UID SEARCH "
        if let charset {
            command += "CHARSET \(charset) "
        } else if parts.contains(where: \.isLiteral) {
            command += "CHARSET UTF-8 "
        }
        var found: [UInt32] = []
        for case let .search(numbers) in try await run([.text(Array(command.utf8))] + parts).untagged {
            found += numbers
        }
        return found
    }

    /// Adds `flags` to the messages, or removes them, without the server answering with the new flags.
    func uidStore(_ uids: [UInt32], adding: Bool, flags: [String]) async throws {
        await acquire()
        defer { release() }
        guard !uids.isEmpty, !flags.isEmpty else { return }
        try await store(uids, adding: adding, flags: flags)
    }

    /// Moves the messages to another folder: UID MOVE where the server offers it, else a copy, the
    /// originals marked \Deleted and expunged.
    func uidMove(_ uids: [UInt32], to rawName: String) async throws {
        await acquire()
        defer { release() }
        guard !uids.isEmpty else { return }
        if capabilities.contains("MOVE") {
            try await run("UID MOVE \(Self.sequenceSet(uids)) \(Self.quoted(rawName))")
        } else {
            try await run("UID COPY \(Self.sequenceSet(uids)) \(Self.quoted(rawName))")
            try await expunge(uids)
        }
    }

    /// Deletes the messages for good: marks them \Deleted and expunges them. Without UIDPLUS the server
    /// can only expunge every message marked \Deleted in the folder, not these alone.
    func uidExpunge(_ uids: [UInt32]) async throws {
        await acquire()
        defer { release() }
        guard !uids.isEmpty else { return }
        try await expunge(uids)
    }

    /// Adds a message to a folder, a draft or a sent copy, and returns its UID when the server tells it
    /// (UIDPLUS's APPENDUID). The message's line ends become CRLF.
    func append(_ rawName: String, message: Data, flags: [String] = [], date: Date? = nil) async throws -> UInt32? {
        await acquire()
        defer { release() }
        var command = "APPEND \(Self.quoted(rawName)) "
        if !flags.isEmpty { command += "(\(flags.joined(separator: " "))) " }
        if let date { command += "\"\(IMAPDate.format(date))\" " }
        let completion = try await run([.text(Array(command.utf8)), .literal(MailWireText.crlfLines(message))])
        guard completion.condition.code == "APPENDUID", completion.condition.codeArguments.count >= 2 else {
            return nil
        }
        return completion.condition.codeArguments[1].number32
    }

    /// Asks the server for what changed (new mail, flags, expunged messages) without doing anything else.
    func noop() async throws {
        await acquire()
        defer { release() }
        try await run("NOOP")
    }

    /// Signs out and closes the connection; a server that has gone away is no failure here.
    func logout() async {
        await acquire()
        defer { release() }
        if socket != nil { _ = try? await run("LOGOUT") }
        drop()
    }

    // MARK: Command arguments

    /// `text` as an IMAP quoted string, `"` and `\` escaped. A quoted string that is not ASCII is sent as
    /// a literal, so this suits search terms and passwords in any language. CR, LF and NUL, which no IMAP
    /// string holds outside a literal, become spaces.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", "\"": out += "\\\(scalar)"
            case "\r", "\n", "\0": out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// UIDs as an IMAP sequence set, runs joined: `[1, 2, 3, 7]` is `1:3,7`.
    static func sequenceSet(_ numbers: [UInt32]) -> String {
        let sorted = Set(numbers).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] &+ 1 { end += 1 }
            ranges.append(end == index ? "\(sorted[index])" : "\(sorted[index]):\(sorted[end])")
            index = end + 1
        }
        return ranges.joined(separator: ",")
    }

    private enum Part {
        case text([UInt8])
        case literal([UInt8])

        var isLiteral: Bool {
            if case .literal = self { true } else { false }
        }
    }

    /// A command's text in parts, each quoted string that holds non-ASCII bytes taken out as a literal:
    /// RFC 3501's quoted strings are ASCII.
    private static func parts(_ command: String) -> [Part] {
        let bytes = Array(command.utf8)
        var parts: [Part] = []
        var text: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x22 else {
                text.append(bytes[index])
                index += 1
                continue
            }
            var content: [UInt8] = []
            var end = index + 1
            var closed = false
            while end < bytes.count {
                if bytes[end] == 0x5C, end + 1 < bytes.count {
                    content.append(bytes[end + 1])
                    end += 2
                } else if bytes[end] == 0x22 {
                    closed = true
                    break
                } else {
                    content.append(bytes[end])
                    end += 1
                }
            }
            guard closed else {
                text += bytes[index...]
                break
            }
            if content.contains(where: { $0 >= 0x80 }) {
                parts.append(.text(text))
                parts.append(.literal(content))
                text = []
            } else {
                text += bytes[index...end]
            }
            index = end + 1
        }
        if !text.isEmpty || parts.isEmpty { parts.append(.text(text)) }
        return parts
    }

    // MARK: Session

    private func openSession(_ socket: any MailSocket) async throws {
        guard case let .untagged(.condition(greeting)) = try await readResponse() else {
            throw IMAPFailure.unexpected("The server sent no greeting.")
        }
        switch greeting.kind {
        case .ok, .preauth: note(.condition(greeting))
        case .bye: throw IMAPFailure.refused(redacted(greeting.text))
        case .no, .bad: throw IMAPFailure.unexpected(redacted(greeting.text))
        }
        if security == .startTLS {
            // A server that says the connection is signed in before TLS began cannot be told to start it.
            guard greeting.kind != .preauth else {
                throw IMAPFailure.unexpected("The server signed in before the connection was encrypted.")
            }
            if capabilities.isEmpty { try await run("CAPABILITY") }
            guard capabilities.contains("STARTTLS") else { throw IMAPFailure.missingCapability("STARTTLS") }
            try await run("STARTTLS")
            buffer.removeAll()
            capabilities = []
            try await socket.startTLS()
            isTLS = true
            try await run("CAPABILITY")
        }
        guard greeting.kind != .preauth else { return }
        if capabilities.isEmpty { try await run("CAPABILITY") }
        try await signIn()
    }

    private func signIn() async throws {
        guard isTLS else {
            throw IMAPFailure.unexpected("The connection is not encrypted, so the client did not sign in.")
        }
        let completion: Completion
        if capabilities.contains("AUTH=PLAIN") {
            let response = Array(plainResponse.utf8)
            var answered = capabilities.contains("SASL-IR")
            let command = answered ? "AUTHENTICATE PLAIN \(plainResponse)" : "AUTHENTICATE PLAIN"
            completion = try await run([.text(Array(command.utf8))], refusal: IMAPFailure.signInRefused) { _ in
                // A second challenge has no answer in PLAIN; `*` cancels the exchange.
                defer { answered = true }
                return answered ? Array("*".utf8) : response
            }
        } else if capabilities.contains("LOGINDISABLED") {
            throw IMAPFailure.missingCapability("a password sign-in")
        } else {
            completion = try await run(Self.parts("LOGIN \(Self.quoted(username)) \(Self.quoted(password))"),
                                       refusal: IMAPFailure.signInRefused)
        }
        let refreshed = completion.condition.code == "CAPABILITY" || completion.untagged.contains {
            if case .capability = $0 { true } else { false }
        }
        if !refreshed { try await run("CAPABILITY") }
    }

    private var plainResponse: String {
        Data([0] + Array(username.utf8) + [0] + Array(password.utf8)).base64EncodedString()
    }

    /// Marks the messages \Deleted and expunges them, by UID where UIDPLUS allows.
    private func expunge(_ uids: [UInt32]) async throws {
        try await store(uids, adding: true, flags: ["\\Deleted"])
        if capabilities.contains("UIDPLUS") {
            try await run("UID EXPUNGE \(Self.sequenceSet(uids))")
        } else {
            try await run("EXPUNGE")
        }
    }

    private func store(_ uids: [UInt32], adding: Bool, flags: [String]) async throws {
        try await run("UID STORE \(Self.sequenceSet(uids)) \(adding ? "+" : "-")FLAGS.SILENT (\(flags.joined(separator: " ")))")
    }

    // MARK: Exchange

    private struct Completion {
        var untagged: [IMAPUntagged]
        var condition: IMAPCondition
    }

    @discardableResult
    private func run(_ command: String) async throws -> Completion {
        try await run(Self.parts(command))
    }

    /// Sends one command and reads until its tagged completion, keeping the untagged responses that came
    /// on the way. A literal waits for the server's `+` unless LITERAL+ (or LITERAL- for small ones) lets
    /// it follow at once; `continuing` answers any other `+`, as a SASL exchange needs.
    @discardableResult
    private func run(_ parts: [Part], refusal: (String) -> IMAPFailure = IMAPFailure.refused,
                     continuing: ((String) -> [UInt8])? = nil) async throws -> Completion {
        let tag = "A\(nextTag)"
        nextTag += 1
        var untagged: [IMAPUntagged] = []
        var pending = Array("\(tag) ".utf8)
        for part in parts {
            switch part {
            case let .text(text):
                pending += text
            case let .literal(bytes):
                let followsAtOnce = capabilities.contains("LITERAL+")
                    || (capabilities.contains("LITERAL-") && bytes.count <= 4096)
                pending += Array("{\(bytes.count)\(followsAtOnce ? "+" : "")}\r\n".utf8)
                if !followsAtOnce {
                    try await write(pending)
                    pending = []
                    waiting: while true {
                        switch try await readResponse() {
                        case .continuation: break waiting
                        case let .untagged(response):
                            note(response)
                            untagged.append(response)
                        case let .tagged(answered, condition):
                            // The server turned the command down before taking the literal.
                            return try complete(tag, answered, condition, untagged, refusal)
                        }
                    }
                }
                pending += bytes
            }
        }
        try await write(pending + [0x0D, 0x0A])
        while true {
            switch try await readResponse() {
            case let .continuation(text):
                guard let continuing else {
                    drop()
                    throw IMAPFailure.unexpected("The server asked for more of a command that was complete.")
                }
                try await write(continuing(text) + [0x0D, 0x0A])
            case let .untagged(response):
                note(response)
                untagged.append(response)
            case let .tagged(answered, condition):
                return try complete(tag, answered, condition, untagged, refusal)
            }
        }
    }

    private func complete(_ tag: String, _ answered: String, _ condition: IMAPCondition,
                          _ untagged: [IMAPUntagged], _ refusal: (String) -> IMAPFailure) throws -> Completion {
        guard answered == tag else {
            drop()
            throw IMAPFailure.unexpected("The server answered command \(answered) while \(tag) was waiting.")
        }
        switch condition.kind {
        case .ok:
            note(.condition(condition))
            return Completion(untagged: untagged, condition: condition)
        case .no, .bad:
            throw refusal(redacted(condition.text))
        case .preauth, .bye:
            drop()
            throw IMAPFailure.unexpected(redacted(condition.text))
        }
    }

    /// Keeps what the server says in passing: its capabilities and the open folder's message count.
    private func note(_ response: IMAPUntagged) {
        switch response {
        case let .capability(names):
            capabilities = Set(names.map { $0.uppercased() })
        case let .condition(condition) where condition.code == "CAPABILITY":
            capabilities = Set(condition.codeArguments.compactMap { $0.text?.uppercased() })
        case let .exists(count):
            selection?.exists = count
        case .expunge:
            if let exists = selection?.exists, exists > 0 { selection?.exists = exists - 1 }
        default:
            break
        }
    }

    /// The server's text with the password, and the PLAIN response that carries it, taken out.
    private func redacted(_ text: String) -> String {
        var text = text
        for secret in [plainResponse, Self.quoted(password), password] where !password.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "••••")
        }
        return text
    }

    // MARK: Reading and writing

    private func write(_ bytes: [UInt8]) async throws {
        guard let socket else { throw MailSocketFailure.closed }
        do {
            try await socket.write(Data(bytes))
        } catch {
            drop()
            throw error
        }
    }

    /// The next whole response, a line and the literals it announces with `{n}` at its end.
    private func readResponse() async throws -> IMAPResponse {
        do {
            var bytes: [UInt8] = []
            while true {
                let line = try await readLine()
                bytes += line
                guard let length = Self.literalLength(endingLine: line) else { break }
                bytes += [0x0D, 0x0A]
                bytes += try await read(length)
            }
            return try IMAPResponse.parse(bytes)
        } catch let IMAPFailure.unexpected(text) {
            drop()
            throw IMAPFailure.unexpected(redacted(text))
        } catch {
            drop()
            throw error
        }
    }

    /// A literal's length when `line` ends by announcing one: `{123}`, or `~{123}` for BINARY's.
    private static func literalLength(endingLine line: [UInt8]) -> Int? {
        guard line.last == 0x7D, let open = line.lastIndex(of: 0x7B) else { return nil }
        let digits = line[(open + 1)..<(line.count - 1)]
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func readLine() async throws -> [UInt8] {
        while true {
            if let line = buffer.takeLine() { return line }
            try await fill()
        }
    }

    private func read(_ count: Int) async throws -> [UInt8] {
        while true {
            if let bytes = buffer.take(count) { return bytes }
            try await fill()
        }
    }

    private func fill() async throws {
        guard let socket else { throw MailSocketFailure.closed }
        let data = try await socket.read()
        guard !data.isEmpty else { throw MailSocketFailure.closed }
        buffer.append(data)
    }

    private func drop() {
        socket?.close()
        socket = nil
        isTLS = false
        buffer.removeAll()
        selection = nil
    }

    // MARK: One command at a time

    /// Waits until no other command is in flight. The actor alone does not serialize them: it lets
    /// another call in while one waits for the server.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
