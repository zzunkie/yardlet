import Foundation

// What an IMAP server sends (RFC 9051 and RFC 3501), read into values the mailbox can use. The client
// (`IMAPClient`) assembles each response with its literals and hands the bytes here.

/// A folder as the server lists it.
struct IMAPMailbox: Hashable, Sendable {
    /// The name people read, decoded from IMAP's modified UTF-7 (`&vPSwuNO4ycDVaA-` is "보낸편지함").
    var name: String
    /// The name as the server sent it, for commands that name the folder.
    var rawName: String
    /// What separates levels in the name (`/`, `.`); nil when the server keeps no hierarchy.
    var delimiter: String?
    /// The folder's attributes, lowercased: `\sent`, `\drafts`, `\junk`, `\trash`, `\archive`, `\all`,
    /// `\noselect`, `\haschildren`.
    var attributes: Set<String>

    /// Whether the folder holds messages that SELECT can open.
    var isSelectable: Bool {
        !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
    }
}

/// A folder's counts from STATUS, read without opening it.
struct IMAPStatus: Hashable, Sendable {
    var messages: Int
    var unseen: Int
    var uidNext: UInt32?
    var uidValidity: UInt32?
}

/// The folder SELECT or EXAMINE opened.
struct IMAPSelection: Hashable, Sendable {
    var exists: Int
    var uidValidity: UInt32?
    var uidNext: UInt32?
}

/// An address of an envelope. The name is as the message's header gave it: RFC 2047 encoded words
/// (`=?UTF-8?B?…?=`) are left for the caller to decode.
struct IMAPAddress: Hashable, Sendable {
    var name: String?
    var mailbox: String
    var host: String

    var address: String { host.isEmpty ? mailbox : "\(mailbox)@\(host)" }
}

/// A message's envelope as the server parsed its header. Strings are as the header gave them: the
/// subject's RFC 2047 encoded words are not decoded and the date is not read.
struct IMAPEnvelope: Hashable, Sendable {
    var date: String?
    var subject: String?
    var from: [IMAPAddress]
    var sender: [IMAPAddress]
    var replyTo: [IMAPAddress]
    var to: [IMAPAddress]
    var cc: [IMAPAddress]
    var bcc: [IMAPAddress]
    var inReplyTo: String?
    var messageID: String?
}

/// A message's MIME structure from BODYSTRUCTURE: enough to fetch the text or HTML part alone and to tell
/// whether the message carries attachments.
struct IMAPBodyStructure: Hashable, Sendable {
    /// The two halves of the MIME type, lowercased: `text` and `plain`, `multipart` and `mixed`.
    var type: String
    var subtype: String
    /// The Content-Type parameters, names lowercased and values as sent: `charset`, `name`, `boundary`.
    var parameters: [String: String]
    var contentID: String?
    /// The Content-Transfer-Encoding, lowercased (`base64`, `quoted-printable`, `7bit`); nil for a
    /// multipart.
    var encoding: String?
    /// The encoded size in bytes; nil for a multipart.
    var size: Int?
    /// The Content-Disposition, lowercased (`attachment`, `inline`), and its parameters, names lowercased.
    var disposition: String?
    var dispositionParameters: [String: String]
    /// The section that `BODY[…]` names this part by: "1", "1.2". A multipart message's top level has
    /// the empty section, and a message of one part has the single section "1".
    var section: String
    /// A multipart's parts, or an attached message's own body.
    var parts: [IMAPBodyStructure]

    var isMultipart: Bool { type == "multipart" }
    var charset: String? { parameters["charset"] }

    /// The file name as sent: the disposition's `filename`, else the type's `name`. Names encoded with
    /// RFC 2047 or RFC 2231 are left for the caller to decode.
    var filename: String? {
        dispositionParameters["filename"] ?? dispositionParameters["filename*"]
            ?? parameters["name"] ?? parameters["name*"]
    }

    /// A part the message carries as a file rather than as its text: one marked as an attachment, an
    /// attached message, or a named part that is not text and not marked inline.
    var isAttachment: Bool {
        guard !isMultipart else { return false }
        if let disposition { return disposition == "attachment" }
        if type == "message" { return true }
        return filename != nil && type != "text"
    }

    var hasAttachments: Bool {
        isMultipart ? parts.contains(where: \.hasAttachments) : isAttachment
    }

    /// The first part of this type and subtype in reading order, outside attachments and attached
    /// messages: `firstPart(type: "text", subtype: "html")`.
    func firstPart(type: String, subtype: String) -> IMAPBodyStructure? {
        if isMultipart {
            for part in parts {
                if let found = part.firstPart(type: type, subtype: subtype) { return found }
            }
            return nil
        }
        guard !isAttachment, self.type == type.lowercased(), self.subtype == subtype.lowercased() else { return nil }
        return self
    }
}

/// What a FETCH response gave for one message. Items the command did not ask for stay empty.
struct IMAPFetch: Hashable, Sendable {
    var sequence: UInt32
    var uid: UInt32?
    /// The flags as sent: `\Seen`, `\Flagged`, `$Forwarded`.
    var flags: Set<String> = []
    var internalDate: Date?
    /// RFC822.SIZE: the whole message's size in bytes.
    var size: Int?
    var envelope: IMAPEnvelope?
    var bodyStructure: IMAPBodyStructure?
    /// `BODY[…]` results by their section as the server named it, uppercased and without the origin:
    /// "1", "1.2", "TEXT", "HEADER", "HEADER.FIELDS (REFERENCES)", and "" for the whole message.
    /// RFC822, RFC822.HEADER and RFC822.TEXT land under "", "HEADER" and "TEXT".
    var sections: [String: Data] = [:]

    /// Adds what another FETCH response for the same message gave: a server may split one message's
    /// items over several responses.
    mutating func merge(_ other: IMAPFetch) {
        uid = other.uid ?? uid
        if !other.flags.isEmpty { flags = other.flags }
        internalDate = other.internalDate ?? internalDate
        size = other.size ?? size
        envelope = other.envelope ?? envelope
        bodyStructure = other.bodyStructure ?? bodyStructure
        sections.merge(other.sections) { _, new in new }
    }
}

/// IMAP's modified UTF-7 for folder names (RFC 3501, section 5.1.3): printable ASCII stands for itself,
/// `&` is written `&-`, and other text is UTF-16 in base64 with `,` for `/` between `&` and `-`.
enum IMAPModifiedUTF7 {
    static func encode(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let bytes = pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let base64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            out += "&\(base64)-"
            pending = []
        }
        for scalar in name.unicodeScalars {
            if (0x20...0x7E).contains(scalar.value) {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += String(scalar).utf16
            }
        }
        flush()
        return out
    }

    /// The name people read; a name that is not valid modified UTF-7 is returned as it is.
    static func decode(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                out.append(scalars[index])
                index += 1
                continue
            }
            guard let end = scalars[(index + 1)...].firstIndex(of: "-") else { return raw }
            let encoded = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            if encoded.isEmpty {
                out.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                guard let data = Data(base64Encoded: base64), data.count % 2 == 0,
                      let text = String(data: data, encoding: .utf16BigEndian) else { return raw }
                out.append(contentsOf: text.unicodeScalars)
            }
            index = end + 1
        }
        return String(out)
    }
}

/// One value of a response: an atom (a word or a number), a string (quoted or a literal), NIL, or a
/// parenthesized list.
enum IMAPValue: Hashable, Sendable {
    case atom(String)
    case string(Data)
    case null
    case list([IMAPValue])

    /// An atom's or a string's text; nil for NIL and lists. Strings that are not UTF-8 are read as
    /// Latin-1, which keeps every byte.
    var text: String? {
        switch self {
        case let .atom(atom): atom
        case let .string(data): IMAPValue.text(data)
        case .null, .list: nil
        }
    }

    var data: Data? {
        switch self {
        case let .string(data): data
        case let .atom(atom): Data(atom.utf8)
        case .null, .list: nil
        }
    }

    var number: UInt64? {
        if case let .atom(atom) = self { return UInt64(atom) }
        return nil
    }

    var number32: UInt32? { number.flatMap { UInt32(exactly: $0) } }

    var list: [IMAPValue]? {
        if case let .list(items) = self { return items }
        return nil
    }

    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// A server's word on a command or on itself, OK, NO, BAD, PREAUTH or BYE, with its response code.
struct IMAPCondition: Hashable, Sendable {
    enum Kind: String, Sendable {
        case ok = "OK", no = "NO", bad = "BAD", preauth = "PREAUTH", bye = "BYE"
    }

    var kind: Kind
    /// The response code's name, uppercased (`APPENDUID`, `CAPABILITY`, `TRYCREATE`), and its arguments.
    var code: String?
    var codeArguments: [IMAPValue] = []
    /// Everything after the condition's word as the server wrote it, the response code included.
    var text: String
}

enum IMAPUntagged: Sendable {
    case condition(IMAPCondition)
    case capability([String])
    case list(IMAPMailbox)
    case status(rawName: String, IMAPStatus)
    case search([UInt32])
    case flags([String])
    case exists(Int)
    case expunge(UInt32)
    case fetch(IMAPFetch)
    /// A response the client has no use for, by its name (`RECENT`, `ENABLED`, `NAMESPACE`).
    case other(String)
}

enum IMAPResponse: Sendable {
    /// `+`: the server waits for the rest of a command; the text is a SASL challenge or a remark.
    case continuation(String)
    case tagged(String, IMAPCondition)
    case untagged(IMAPUntagged)

    /// Reads one whole response, its literals included as they arrived (`{5}` CRLF and five bytes).
    static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        var parser = IMAPParser(bytes)
        if parser.consume(.plus) {
            parser.skipSpaces()
            return .continuation(parser.rest())
        }
        if parser.consume(.asterisk) {
            try parser.space()
            return .untagged(try untagged(&parser))
        }
        let tag = parser.atom()
        try parser.space()
        guard !tag.isEmpty, let kind = IMAPCondition.Kind(rawValue: parser.atom().uppercased()) else {
            throw parser.failure()
        }
        return .tagged(tag, parser.condition(kind))
    }

    private static func untagged(_ parser: inout IMAPParser) throws -> IMAPUntagged {
        if let first = parser.peek(), first.isDigit {
            let number = try parser.number()
            try parser.space()
            switch parser.atom().uppercased() {
            case "EXISTS": return .exists(Int(clamping: number))
            case "EXPUNGE": return .expunge(UInt32(clamping: number))
            case "FETCH":
                try parser.space()
                return .fetch(try fetch(&parser, sequence: UInt32(clamping: number)))
            case let name: return .other(name)
            }
        }
        let name = parser.atom().uppercased()
        if let kind = IMAPCondition.Kind(rawValue: name) {
            return .condition(parser.condition(kind))
        }
        switch name {
        case "CAPABILITY":
            return .capability(parser.rest().split(separator: " ").map(String.init))
        case "LIST":
            parser.skipSpaces()
            let attributes = try parser.value().list?.compactMap { $0.text?.lowercased() } ?? []
            parser.skipSpaces()
            let delimiter = try parser.value().text
            parser.skipSpaces()
            let rawName = try parser.astring()
            let name = rawName.uppercased() == "INBOX" ? "INBOX"
                : rawName.allSatisfy(\.isASCII) ? IMAPModifiedUTF7.decode(rawName) : rawName
            return .list(IMAPMailbox(name: name, rawName: rawName, delimiter: delimiter,
                                     attributes: Set(attributes)))
        case "STATUS":
            parser.skipSpaces()
            let rawName = try parser.astring()
            parser.skipSpaces()
            let items = try parser.value().list ?? []
            var counts: [String: UInt64] = [:]
            for pair in stride(from: 0, to: items.count - 1, by: 2) {
                if let item = items[pair].text?.uppercased(), let count = items[pair + 1].number {
                    counts[item] = count
                }
            }
            return .status(rawName: rawName, IMAPStatus(
                messages: Int(clamping: counts["MESSAGES"] ?? 0),
                unseen: Int(clamping: counts["UNSEEN"] ?? 0),
                uidNext: counts["UIDNEXT"].flatMap { UInt32(exactly: $0) },
                uidValidity: counts["UIDVALIDITY"].flatMap { UInt32(exactly: $0) }
            ))
        case "SEARCH":
            var numbers: [UInt32] = []
            while true {
                parser.skipSpaces()
                guard !parser.atEnd else { break }
                // A CONDSTORE server ends the list with `(MODSEQ n)`, which is not a result.
                if let number = try parser.value().number32 { numbers.append(number) }
            }
            return .search(numbers)
        case "FLAGS":
            parser.skipSpaces()
            return .flags(try parser.value().list?.compactMap(\.text) ?? [])
        default:
            return .other(name)
        }
    }

    private static func fetch(_ parser: inout IMAPParser, sequence: UInt32) throws -> IMAPFetch {
        var fetch = IMAPFetch(sequence: sequence)
        try parser.expect(.openParen)
        while true {
            parser.skipSpaces()
            if parser.consume(.closeParen) { break }
            let name = parser.atom(endingAt: IMAPParser.endsAttributeName).uppercased()
            guard !name.isEmpty else { throw parser.failure() }
            if parser.peek() == .openBracket {
                let section = try parser.section().uppercased()
                parser.skipOrigin()
                parser.skipSpaces()
                let value = try parser.value()
                if name.hasPrefix("BODY"), let data = value.data { fetch.sections[section] = data }
                continue
            }
            parser.skipSpaces()
            let value = try parser.value()
            switch name {
            case "UID": fetch.uid = value.number32
            case "FLAGS": fetch.flags = Set(value.list?.compactMap(\.text) ?? [])
            case "INTERNALDATE": fetch.internalDate = value.text.flatMap(IMAPDate.parse)
            case "RFC822.SIZE": fetch.size = value.number.map { Int(clamping: $0) }
            case "ENVELOPE": fetch.envelope = IMAPEnvelope(value)
            case "BODYSTRUCTURE", "BODY": fetch.bodyStructure = IMAPBodyStructure(value) ?? fetch.bodyStructure
            case "RFC822": fetch.sections[""] = value.data
            case "RFC822.HEADER": fetch.sections["HEADER"] = value.data
            case "RFC822.TEXT": fetch.sections["TEXT"] = value.data
            default: break
            }
        }
        return fetch
    }
}

extension IMAPEnvelope {
    init?(_ value: IMAPValue) {
        guard let fields = value.list, fields.count >= 10 else { return nil }
        func addresses(_ value: IMAPValue) -> [IMAPAddress] {
            (value.list ?? []).compactMap { entry in
                // A group's start and end carry no host (RFC 3501, section 7.4.2); only members are kept.
                guard let parts = entry.list, parts.count >= 4,
                      let mailbox = parts[2].text, let host = parts[3].text else { return nil }
                return IMAPAddress(name: parts[0].text, mailbox: mailbox, host: host)
            }
        }
        self.init(
            date: fields[0].text, subject: fields[1].text,
            from: addresses(fields[2]), sender: addresses(fields[3]), replyTo: addresses(fields[4]),
            to: addresses(fields[5]), cc: addresses(fields[6]), bcc: addresses(fields[7]),
            inReplyTo: fields[8].text, messageID: fields[9].text
        )
    }
}

extension IMAPBodyStructure {
    init?(_ value: IMAPValue) {
        self.init(value, section: "1", multipartSection: "")
    }

    /// `section` names the part when it is a single part; a multipart is named `multipartSection` and
    /// numbers its parts beneath it. An attached message's body is numbered beneath the message's part.
    private init?(_ value: IMAPValue, section: String, multipartSection: String) {
        guard let fields = value.list, let first = fields.first else { return nil }
        if first.list != nil {
            var parts: [IMAPBodyStructure] = []
            var index = 0
            while index < fields.count, fields[index].list != nil {
                let number = multipartSection.isEmpty ? "\(index + 1)" : "\(multipartSection).\(index + 1)"
                if let part = IMAPBodyStructure(fields[index], section: number, multipartSection: number) {
                    parts.append(part)
                }
                index += 1
            }
            let disposition = Self.disposition(fields[safe: index + 2])
            self.init(type: "multipart", subtype: fields[safe: index]?.text?.lowercased() ?? "mixed",
                      parameters: Self.parameters(fields[safe: index + 1]), contentID: nil,
                      encoding: nil, size: nil, disposition: disposition.kind,
                      dispositionParameters: disposition.parameters, section: multipartSection, parts: parts)
            return
        }
        guard fields.count >= 7 else { return nil }
        let type = fields[0].text?.lowercased() ?? "application"
        let subtype = fields[1].text?.lowercased() ?? "octet-stream"
        var parts: [IMAPBodyStructure] = []
        var extensionStart = 7
        if type == "message", subtype == "rfc822" || subtype == "global", fields.count >= 10,
           fields[8].list != nil {
            parts = [IMAPBodyStructure(fields[8], section: "\(section).1", multipartSection: section)]
                .compactMap { $0 }
            extensionStart = 10
        } else if type == "text" {
            extensionStart = 8
        }
        let disposition = Self.disposition(fields[safe: extensionStart + 1])
        self.init(type: type, subtype: subtype, parameters: Self.parameters(fields[2]),
                  contentID: fields[3].text, encoding: fields[5].text?.lowercased(),
                  size: fields[6].number.map { Int(clamping: $0) }, disposition: disposition.kind,
                  dispositionParameters: disposition.parameters, section: section, parts: parts)
    }

    private static func parameters(_ value: IMAPValue?) -> [String: String] {
        guard let items = value?.list else { return [:] }
        var parameters: [String: String] = [:]
        for pair in stride(from: 0, to: items.count - 1, by: 2) {
            if let name = items[pair].text?.lowercased(), let value = items[pair + 1].text {
                parameters[name] = value
            }
        }
        return parameters
    }

    private static func disposition(_ value: IMAPValue?) -> (kind: String?, parameters: [String: String]) {
        if let items = value?.list, let kind = items.first?.text {
            return (kind.lowercased(), parameters(items[safe: 1]))
        }
        return (value?.text?.lowercased(), [:])
    }
}

/// INTERNALDATE and APPEND's date: `17-Jul-1996 02:44:25 -0700`.
enum IMAPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parse(_ text: String) -> Date? {
        let fields = text.split(separator: " ")
        guard fields.count == 3 else { return nil }
        let day = fields[0].split(separator: "-")
        let time = fields[1].split(separator: ":").compactMap { Int($0) }
        let zone = fields[2]
        guard day.count == 3, let dayNumber = Int(day[0]), let year = Int(day[2]),
              let month = months.firstIndex(of: day[1].lowercased()), time.count == 3,
              zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
              let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(year: year, month: month + 1, day: dayNumber,
                                        hour: time[0], minute: time[1], second: time[2])
        guard let utc = calendar.date(from: components) else { return nil }
        let offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return utc.addingTimeInterval(TimeInterval(-offset))
    }

    /// The date in UTC, as APPEND takes it.
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ number: Int?) -> String {
            let number = number ?? 0
            return number < 10 ? "0\(number)" : "\(number)"
        }
        let month = months[((parts.month ?? 1) - 1) % 12].capitalized
        return "\(two(parts.day))-\(month)-\(parts.year ?? 1970) \(two(parts.hour)):\(two(parts.minute)):\(two(parts.second)) +0000"
    }
}

/// A cursor over one response's bytes.
struct IMAPParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var atEnd: Bool { index >= bytes.count }

    func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw failure() }
    }

    mutating func space() throws {
        try expect(.space)
        skipSpaces()
    }

    mutating func skipSpaces() {
        while peek() == .space { index += 1 }
    }

    /// The rest of the response as text, trimmed.
    mutating func rest() -> String {
        let text = IMAPValue.text(Data(bytes[min(index, bytes.count)...]))
        index = bytes.count
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func endsAtom(_ byte: UInt8) -> Bool {
        byte <= .space || byte == 0x7F || byte == .openParen || byte == .closeParen || byte == .quote
            || byte == .closeBracket
    }

    static func endsAttributeName(_ byte: UInt8) -> Bool {
        endsAtom(byte) || byte == .openBracket
    }

    /// A folder name may hold brackets (`[Gmail]/Spam`) when it is not quoted.
    static func endsAString(_ byte: UInt8) -> Bool {
        byte <= .space || byte == 0x7F || byte == .openParen || byte == .closeParen || byte == .quote
    }

    mutating func atom(endingAt ends: (UInt8) -> Bool = IMAPParser.endsAtom) -> String {
        let start = index
        while let byte = peek(), !ends(byte) { index += 1 }
        return IMAPValue.text(Data(bytes[start..<index]))
    }

    mutating func number() throws -> UInt64 {
        guard let number = UInt64(atom()) else { throw failure() }
        return number
    }

    /// A string, quoted or a literal, or an atom that may hold brackets.
    mutating func astring() throws -> String {
        switch peek() {
        case .quote, .openBrace, .tilde:
            guard let text = try value().text else { throw failure() }
            return text
        default:
            let atom = atom(endingAt: IMAPParser.endsAString)
            guard !atom.isEmpty else { throw failure() }
            return atom
        }
    }

    mutating func value() throws -> IMAPValue {
        switch peek() {
        case .openParen:
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                if consume(.closeParen) { return .list(items) }
                guard !atEnd else { throw failure() }
                items.append(try value())
            }
        case .quote:
            return .string(try quoted())
        case .openBrace:
            return .string(try literal())
        case .tilde where index + 1 < bytes.count && bytes[index + 1] == .openBrace:
            index += 1
            return .string(try literal())
        case nil:
            throw failure()
        default:
            let atom = atom()
            guard !atom.isEmpty else { throw failure() }
            return atom.uppercased() == "NIL" ? .null : .atom(atom)
        }
    }

    /// What OK, NO, BAD, PREAUTH or BYE says: the response code in brackets and the text.
    mutating func condition(_ kind: IMAPCondition.Kind) -> IMAPCondition {
        skipSpaces()
        let textStart = index
        var code: String?
        var arguments: [IMAPValue] = []
        if consume(.openBracket) {
            code = atom().uppercased()
            while true {
                skipSpaces()
                guard let byte = peek(), byte != .closeBracket else { break }
                guard let argument = try? value() else {
                    // An argument this reader cannot take apart is passed over, up to the code's end.
                    while let byte = peek(), byte != .closeBracket { index += 1 }
                    break
                }
                arguments.append(argument)
            }
            _ = consume(.closeBracket)
        }
        index = textStart
        return IMAPCondition(kind: kind, code: code, codeArguments: arguments, text: rest())
    }

    /// A FETCH item's section, from `[` to its `]`: `1.2`, `HEADER.FIELDS (REFERENCES)`.
    mutating func section() throws -> String {
        try expect(.openBracket)
        let start = index
        var quoted = false
        while let byte = peek() {
            if byte == .quote { quoted.toggle() }
            if byte == .closeBracket, !quoted {
                let section = IMAPValue.text(Data(bytes[start..<index]))
                index += 1
                return section
            }
            index += 1
        }
        throw failure()
    }

    /// A partial FETCH's `<origin>`, which the section's key leaves out.
    mutating func skipOrigin() {
        guard consume(.lessThan) else { return }
        while let byte = peek(), byte != .greaterThan { index += 1 }
        _ = consume(.greaterThan)
    }

    private mutating func quoted() throws -> Data {
        try expect(.quote)
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == .backslash, index < bytes.count {
                out.append(bytes[index])
                index += 1
            } else if byte == .quote {
                return Data(out)
            } else {
                out.append(byte)
            }
        }
        throw failure()
    }

    private mutating func literal() throws -> Data {
        try expect(.openBrace)
        guard let length = Int(atom(endingAt: { !$0.isDigit })) else { throw failure() }
        _ = consume(.plus)
        try expect(.closeBrace)
        _ = consume(.carriageReturn)
        try expect(.lineFeed)
        guard length <= bytes.count - index else { throw failure() }
        let data = Data(bytes[index..<index + length])
        index += length
        return data
    }

    /// The response could not be read; the error shows how it began.
    func failure() -> IMAPFailure {
        .unexpected(IMAPValue.text(Data(bytes.prefix(160))))
    }
}

extension UInt8 {
    fileprivate static let space: UInt8 = 0x20
    fileprivate static let quote: UInt8 = 0x22
    fileprivate static let openParen: UInt8 = 0x28
    fileprivate static let closeParen: UInt8 = 0x29
    fileprivate static let asterisk: UInt8 = 0x2A
    fileprivate static let plus: UInt8 = 0x2B
    fileprivate static let lessThan: UInt8 = 0x3C
    fileprivate static let greaterThan: UInt8 = 0x3E
    fileprivate static let openBracket: UInt8 = 0x5B
    fileprivate static let backslash: UInt8 = 0x5C
    fileprivate static let closeBracket: UInt8 = 0x5D
    fileprivate static let openBrace: UInt8 = 0x7B
    fileprivate static let closeBrace: UInt8 = 0x7D
    fileprivate static let tilde: UInt8 = 0x7E
    fileprivate static let carriageReturn: UInt8 = 0x0D
    fileprivate static let lineFeed: UInt8 = 0x0A

    fileprivate var isDigit: Bool { (0x30...0x39).contains(self) }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
