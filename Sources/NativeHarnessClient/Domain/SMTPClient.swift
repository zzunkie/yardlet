import Foundation

/// Why a message was not sent, with the server's reply code and words where it gave them. The account's
/// password never appears in it.
enum SMTPFailure: Error, Equatable, LocalizedError {
    /// The server turned down a step with a 4xx (try again later) or 5xx (will not) reply.
    case refused(code: Int, text: String)
    /// The server turned down the account's name and password: 535, or another failed AUTH reply.
    case signInRefused(code: Int, text: String)
    /// The server lacks what the client needs: STARTTLS on a connection that starts plain, or AUTH.
    case missingCapability(String)
    /// An address the client will not put in a command: empty, or holding CR, LF, `<` or `>`.
    case invalidAddress(String)
    case noRecipients
    /// The server sent something the client could not read or did not expect.
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case let .refused(code, text): "The mail server refused the message (\(code)): \(text)"
        case let .signInRefused(code, text): "The mail server did not accept the name and password (\(code)): \(text)"
        case let .missingCapability(name): "The mail server does not offer \(name)."
        case let .invalidAddress(address): "“\(address)” is not an address a message can be sent to."
        case .noRecipients: "The message has no recipients."
        case let .unexpected(text): "The mail server sent a reply that could not be read: \(text)"
        }
    }
}

/// Hands messages to a service's submission server (RFC 6409 over RFC 5321), for the services the
/// mailbox sends through without an API. Each `send` is a connection of its own: greeting, EHLO,
/// STARTTLS when the connection starts plain, AUTH PLAIN (or AUTH LOGIN) only over TLS, the envelope,
/// the message and QUIT.
struct SMTPClient: Sendable {
    let opener: any MailSocketOpening
    let host: String
    let port: Int
    let security: MailSocketSecurity
    let username: String
    let password: String
    /// The name the client gives in EHLO. An address literal, as other mail apps send, rather than the
    /// computer's own name, which submission servers do not check.
    var clientName = "[127.0.0.1]"

    init(opener: any MailSocketOpening, host: String, port: Int, security: MailSocketSecurity,
         username: String, password: String) {
        self.opener = opener
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
    }

    /// Sends `message`, a whole RFC 5322 message, from `from` to every address in `recipients` (Bcc
    /// included: they are the envelope, not the header). Line ends become CRLF on the way. A refused
    /// recipient stops the whole send, so no one gets a message others did not.
    func send(message: Data, from: String, recipients: [String]) async throws {
        try Self.checkAddress(from)
        guard !recipients.isEmpty else { throw SMTPFailure.noRecipients }
        for recipient in recipients { try Self.checkAddress(recipient) }
        try await converse { connection in
            let extensions = try await signIn(connection)
            try await submit(message, from: from, recipients: recipients, extensions: extensions, over: connection)
        }
    }

    /// Signs in and says goodbye without sending anything, to confirm an account's server and password.
    /// A refused password throws `SMTPFailure.signInRefused`, as `send` does.
    func check() async throws {
        try await converse { connection in
            _ = try await signIn(connection)
            await connection.quitQuietly()
        }
    }

    /// One connection for `body`, closed after it. A server that turned a step down hears QUIT first.
    private func converse(_ body: (SMTPConnection) async throws -> Void) async throws {
        let socket = try await opener.open(host: host, port: port, tls: security == .tls)
        defer { socket.close() }
        let connection = SMTPConnection(socket: socket, isTLS: security == .tls, secrets: secrets)
        do {
            try await body(connection)
        } catch let failure as SMTPFailure {
            switch failure {
            case .refused, .signInRefused, .missingCapability: await connection.quitQuietly()
            default: break
            }
            throw failure
        }
    }

    /// The greeting, EHLO, STARTTLS and EHLO again when the connection starts plain, and AUTH; returns
    /// the extensions the server offers once TLS is on.
    private func signIn(_ connection: SMTPConnection) async throws -> [String: [String]] {
        try await connection.expect(connection.reply(), 220)
        var extensions = try await hello(connection)
        if security == .startTLS {
            guard extensions["STARTTLS"] != nil else { throw SMTPFailure.missingCapability("STARTTLS") }
            try await connection.command("STARTTLS", expecting: 220)
            try await connection.startTLS()
            extensions = try await hello(connection)
        }
        try await authenticate(connection, mechanisms: Set(extensions["AUTH"] ?? []))
        return extensions
    }

    private func submit(_ message: Data, from: String, recipients: [String], extensions: [String: [String]],
                        over connection: SMTPConnection) async throws {
        let payload = MailWireText.crlfLines(message, dotStuffed: true)
        var mail = "MAIL FROM:<\(from)>"
        if extensions["8BITMIME"] != nil, payload.contains(where: { $0 >= 0x80 }) { mail += " BODY=8BITMIME" }
        if extensions["SMTPUTF8"] != nil, ([from] + recipients).contains(where: { !$0.allSatisfy(\.isASCII) }) {
            mail += " SMTPUTF8"
        }
        try await connection.command(mail, expecting: 250)
        for recipient in recipients {
            try await connection.command("RCPT TO:<\(recipient)>", expecting: 250, 251)
        }
        try await connection.command("DATA", expecting: 354)
        var data = payload
        if !data.isEmpty, data.suffix(2) != [0x0D, 0x0A] { data += [0x0D, 0x0A] }
        data += Array(".\r\n".utf8)
        try await connection.write(data)
        try await connection.expect(connection.reply(), 250)
        await connection.quitQuietly()
    }

    /// EHLO's extensions by keyword, uppercased, each with its parameters uppercased: `AUTH` with
    /// `PLAIN`, `LOGIN`; `SIZE` with its limit.
    private func hello(_ connection: SMTPConnection) async throws -> [String: [String]] {
        let reply = try await connection.command("EHLO \(clientName)", expecting: 250)
        var extensions: [String: [String]] = [:]
        for line in reply.lines.dropFirst() {
            let words = line.split(separator: " ").map { $0.uppercased() }
            guard let keyword = words.first else { continue }
            // Some servers still write the AUTH line of an early draft: `AUTH=PLAIN LOGIN`.
            if keyword.hasPrefix("AUTH=") {
                extensions["AUTH", default: []] += [String(keyword.dropFirst(5))] + words.dropFirst()
            } else {
                extensions[keyword, default: []] += words.dropFirst()
            }
        }
        return extensions
    }

    private func authenticate(_ connection: SMTPConnection, mechanisms: Set<String>) async throws {
        guard connection.isTLS else {
            throw SMTPFailure.unexpected("The connection is not encrypted, so the client did not sign in.")
        }
        if mechanisms.contains("PLAIN") {
            var reply = try await connection.reply(to: "AUTH PLAIN \(plainResponse)")
            // A server may ask for the response again after an empty challenge.
            if reply.code == 334 { reply = try await connection.reply(to: plainResponse) }
            try connection.expectSignedIn(reply, 235)
        } else if mechanisms.contains("LOGIN") {
            try connection.expectSignedIn(await connection.reply(to: "AUTH LOGIN"), 334)
            try connection.expectSignedIn(await connection.reply(to: Self.base64(username)), 334)
            try connection.expectSignedIn(await connection.reply(to: Self.base64(password)), 235)
        } else {
            throw SMTPFailure.missingCapability("AUTH PLAIN or AUTH LOGIN")
        }
    }

    private var plainResponse: String {
        Data([0] + Array(username.utf8) + [0] + Array(password.utf8)).base64EncodedString()
    }

    /// What a server's words must not repeat in an error: the password and the AUTH responses carrying it.
    private var secrets: [String] {
        password.isEmpty ? [] : [plainResponse, Self.base64(password), password]
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// An address goes inside `<…>` on a command line, so one that could end the line or the brackets is
    /// refused before anything is sent.
    private static func checkAddress(_ address: String) throws {
        guard !address.isEmpty, !address.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || $0 == "<" || $0 == ">"
        }) else { throw SMTPFailure.invalidAddress(address) }
    }
}

/// A server's reply: its three-digit code and the text of each line, the code taken off.
struct SMTPReply: Equatable, Sendable {
    var code: Int
    var lines: [String]

    var text: String { lines.joined(separator: "\n") }
}

/// One SMTP connection's reading and writing, for a single `send`.
private final class SMTPConnection {
    private let socket: any MailSocket
    private var buffer = MailReadBuffer()
    private(set) var isTLS: Bool
    private let secrets: [String]

    init(socket: any MailSocket, isTLS: Bool, secrets: [String]) {
        self.socket = socket
        self.isTLS = isTLS
        self.secrets = secrets
    }

    func write(_ bytes: [UInt8]) async throws {
        try await socket.write(Data(bytes))
    }

    /// Sends one command line and reads the server's reply.
    func reply(to line: String) async throws -> SMTPReply {
        try await write(Array("\(line)\r\n".utf8))
        return try await reply()
    }

    @discardableResult
    func command(_ line: String, expecting codes: Int...) async throws -> SMTPReply {
        let reply = try await reply(to: line)
        try expect(reply, codes)
        return reply
    }

    func expect(_ reply: SMTPReply, _ codes: Int...) throws {
        try expect(reply, codes)
    }

    private func expect(_ reply: SMTPReply, _ codes: [Int]) throws {
        guard !codes.contains(reply.code) else { return }
        if (400..<600).contains(reply.code) {
            throw SMTPFailure.refused(code: reply.code, text: redacted(reply.text))
        }
        throw SMTPFailure.unexpected("\(reply.code) \(redacted(reply.text))")
    }

    func expectSignedIn(_ reply: SMTPReply, _ code: Int) throws {
        guard reply.code != code else { return }
        if (400..<600).contains(reply.code) {
            throw SMTPFailure.signInRefused(code: reply.code, text: redacted(reply.text))
        }
        throw SMTPFailure.unexpected("\(reply.code) \(redacted(reply.text))")
    }

    /// Reads a reply of one line or several (`250-…` lines ending with `250 …`).
    func reply() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await readLine(), as: UTF8.self)
            let code = line.prefix(3)
            guard code.count == 3, code.allSatisfy(\.isNumber), let number = Int(code) else {
                throw SMTPFailure.unexpected(redacted(String(line.prefix(160))))
            }
            let separator = line.dropFirst(3).first
            lines.append(String(line.dropFirst(4)))
            if separator != "-" { return SMTPReply(code: number, lines: lines) }
        }
    }

    /// Upgrades the connection after the server's 220 to STARTTLS. Whatever the server sent before TLS
    /// began is dropped: bytes sent in plain text after the 220 are not the server's to trust.
    func startTLS() async throws {
        buffer.removeAll()
        try await socket.startTLS()
        isTLS = true
    }

    /// Says goodbye where the server can still hear it; a server that has gone is no failure here.
    func quitQuietly() async {
        _ = try? await reply(to: "QUIT")
    }

    private func readLine() async throws -> [UInt8] {
        while true {
            if let line = buffer.takeLine() { return line }
            let data = try await socket.read()
            guard !data.isEmpty else { throw MailSocketFailure.closed }
            buffer.append(data)
        }
    }

    private func redacted(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••") }
    }
}
