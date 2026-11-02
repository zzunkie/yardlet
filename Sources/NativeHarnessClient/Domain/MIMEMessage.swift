import Foundation

/// RFC 2047 encoded words in a header (`=?UTF-8?B?…?=`, `=?ks_c_5601-1987?Q?…?=`), in any charset
/// `MIMECharset` reads. Adjacent words are joined without the whitespace between them, and the bytes of
/// adjacent words in one charset are read together, since mailers split a character between two words.
/// A word in an unknown charset, or whose bytes are not text in it, stays as it is.
enum MIMEWords {
    static func decode(_ header: String) -> String {
        guard header.contains("=?") else { return header }
        let source = header as NSString
        let matches = pattern.matches(in: header, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return header }
        var output = ""
        var last = 0
        // The words read so far that nothing but whitespace separates: their encoding, bytes and span.
        var run: (encoding: String.Encoding, bytes: [UInt8], start: Int, end: Int)?
        func flush() {
            guard let current = run else { return }
            output += String(bytes: current.bytes, encoding: current.encoding)
                ?? source.substring(with: NSRange(location: current.start, length: current.end - current.start))
            run = nil
        }
        for match in matches {
            let gap = source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let charset = source.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? ""
            guard let encoding = MIMECharset.encoding(named: charset) else {
                flush()
                output += gap + source.substring(with: match.range)
                continue
            }
            let encoded = Array(source.substring(with: match.range(at: 3)).utf8)[...]
            let bytes = source.substring(with: match.range(at: 2)).uppercased() == "B"
                ? MIMETransfer.base64(encoded) : MIMETransfer.qEncoding(encoded)
            if let current = run, gap.allSatisfy(\.isWhitespace) {
                if current.encoding == encoding {
                    run = (encoding, current.bytes + bytes, current.start, last)
                    continue
                }
                flush()
            } else {
                flush()
                output += gap
            }
            run = (encoding, bytes, match.range.location, last)
        }
        flush()
        output += source.substring(from: last)
        return output
    }

    private static let pattern = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=")
}

/// The text encodings mail declares in `charset=` and in encoded words, under the names mail really
/// carries. Korean mail labelled `ks_c_5601-1987`, `euc-kr` or `cp949` is read as Windows code page 949,
/// the superset Korean mailers write; `gb2312` as GB 18030, `shift_jis` as code page 932 and `iso-8859-1`
/// as Windows-1252, for the same reason.
enum MIMECharset {
    static func encoding(named name: String) -> String.Encoding? {
        let key = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        switch key {
        case "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8": return .utf8
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "windows-1252", "cp1252": return .windowsCP1252
        default: break
        }
        #if canImport(Darwin)
        let cf: CFStringEncoding = if korean.contains(key) {
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        } else if chinese.contains(key) {
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        } else if japanese.contains(key) {
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
        } else {
            CFStringConvertIANACharSetNameToEncoding(key as CFString)
        }
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        #else
        let iana = korean.contains(key) ? "cp949" : chinese.contains(key) ? "gb18030"
            : japanese.contains(key) ? "windows-31j" : key
        return String.Encoding(ianaName: iana)
        #endif
    }

    /// Bytes as text in `charset` (UTF-8 when none is given), leaving out a character cut off at the end;
    /// else as UTF-8; else as Latin-1, which reads any bytes.
    static func string(_ data: Data, charset: String?) -> String {
        let declared = charset.flatMap(encoding(named:)) ?? .utf8
        for cut in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(cut), encoding: declared) { return text }
        }
        if declared != .utf8, let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static let korean: Set = [
        "ks_c_5601-1987", "ks_c_5601-1989", "ks_c_5601", "ksc5601", "ksc_5601", "euc-kr", "euckr", "x-euc-kr",
        "cp949", "ms949", "windows-949", "x-windows-949", "uhc", "korean", "csksc56011987", "iso-ir-149",
    ]
    private static let chinese: Set = ["gb2312", "gbk", "x-gbk", "cp936", "gb18030", "csgb2312", "euc-cn", "x-euc-cn"]
    private static let japanese: Set = ["shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "windows-31j", "cp932", "csshiftjis"]
}

/// One MIME entity: a whole message or one of its parts.
struct MIMEPart: Sendable {
    /// The header fields in order, unfolded, as the message wrote them: encoded words are not decoded.
    var headers: [(name: String, value: String)]
    /// The lowercased `type/subtype`: `text/plain` when the header is missing or unreadable, and
    /// `message/rfc822` for a part of a `multipart/digest`.
    var contentType: String
    /// The `Content-Type` parameters by lowercased name, RFC 2231 continuations joined and read in their
    /// charset.
    var parameters: [String: String]
    /// The lowercased `Content-Disposition`, such as `attachment` or `inline`.
    var disposition: String?
    /// `Content-Disposition`'s `filename`, else `Content-Type`'s `name`, with its encoded words decoded.
    var filename: String?
    /// A multipart's parts, or the one message a `message/rfc822` part holds.
    var children: [MIMEPart]
    /// The content with its transfer encoding undone. A multipart's is empty: its content is its children.
    var body: Data

    /// The first field of this name; names are case-insensitive.
    func header(_ name: String) -> String? {
        MIMEMessage.value(of: name, in: headers)
    }

    /// A `text/*` part's body in its charset, line breaks as `\n`.
    var text: String? {
        guard contentType.hasPrefix("text/") else { return nil }
        return MIMECharset.string(body, charset: parameters["charset"]).replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// Reads a raw RFC 5322 message, as an IMAP server returns it, into its MIME parts.
enum MIMEMessage {
    /// How deep parts may nest; a part deeper than this is read as one leaf.
    static let depthLimit = 32

    /// The message and its parts, on a best effort: broken input still gives a part, never an error.
    static func parse(_ raw: Data) -> MIMEPart {
        let bytes = [UInt8](raw)
        return entity(bytes[...], defaultType: "text/plain", depth: 0)
    }

    fileprivate static func entity(_ bytes: ArraySlice<UInt8>, defaultType: String, depth: Int) -> MIMEPart {
        let (headers, content) = MIMEHeaders.split(bytes)
        return entity(headers: headers, content: content, defaultType: defaultType, depth: depth)
    }

    /// A part from its header fields and its still encoded content.
    fileprivate static func entity(headers: [(name: String, value: String)], content: ArraySlice<UInt8>,
                       defaultType: String, depth: Int) -> MIMEPart {
        let type = MIMEHeaderValue(value(of: "Content-Type", in: headers) ?? "")
        let contentType = type.isMediaType ? type.value : defaultType
        let disposition = value(of: "Content-Disposition", in: headers).map(MIMEHeaderValue.init)
        let filename = (disposition?.parameters["filename"] ?? type.parameters["name"])
            .map { MIMEWords.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let decoded = MIMETransfer.decode(content, encoding: value(of: "Content-Transfer-Encoding", in: headers))
        var children: [MIMEPart] = []
        var body = Data()
        if depth < depthLimit, contentType.hasPrefix("multipart/"),
           case let parts = MIMEMultipart.parts(of: decoded, boundary: type.parameters["boundary"]), !parts.isEmpty {
            let childType = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
            children = parts.map { entity($0, defaultType: childType, depth: depth + 1) }
        } else if depth < depthLimit, contentType == "message/rfc822" || contentType == "message/global" {
            children = [entity(decoded, defaultType: "text/plain", depth: depth + 1)]
            body = Data(decoded)
        } else {
            body = Data(decoded)
        }
        return MIMEPart(
            headers: headers,
            contentType: contentType,
            parameters: type.parameters,
            disposition: disposition.map(\.value).flatMap { $0.isEmpty ? nil : $0 },
            filename: filename.flatMap { $0.isEmpty ? nil : $0 },
            children: children,
            body: body
        )
    }

    fileprivate static func value(of name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension MIMEPart {
    /// The first `text/plain` body not marked as an attachment: the plain alternative of a
    /// `multipart/alternative`, inside the first part of a `multipart/mixed` or `related` that holds a
    /// body, and a forwarded message's only when nothing else holds one.
    var plainText: String? { bodies.plain.map { part(at: $0) }?.text }

    /// The first `text/html` body not marked as an attachment, chosen the same way.
    var html: String? { bodies.html.map { part(at: $0) }?.text }

    /// The parts a person would save: those with a file name (inline images among them), those marked as
    /// attachments, and forwarded messages, leaving out the parts read as `plainText` and `html`.
    var attachments: [MIMEPart] {
        let chosen = bodies
        var found: [MIMEPart] = []
        func walk(_ part: MIMEPart, _ path: [Int]) {
            if path.isEmpty, part.isMessage { return walk(part.children[0], [0]) }
            if part.contentType.hasPrefix("multipart/"), !part.children.isEmpty {
                for (index, child) in part.children.enumerated() { walk(child, path + [index]) }
                return
            }
            guard path != chosen.plain, path != chosen.html else { return }
            if part.isMessage || part.filename != nil || part.disposition == "attachment" { found.append(part) }
        }
        walk(self, [])
        return found
    }

    /// The body as text: `plainText` when it has any, else `html` read as text, else empty.
    var bodyText: String {
        if let plain = plainText, plain.contains(where: { !$0.isWhitespace }) { return plain }
        return html.map(GmailText.plainText(fromHTML:)) ?? plainText ?? ""
    }

    private var isMessage: Bool {
        (contentType == "message/rfc822" || contentType == "message/global") && children.count == 1
    }

    private func part(at path: [Int]) -> MIMEPart {
        path.reduce(self) { $0.children[$1] }
    }

    /// Where the plain and HTML bodies are in the tree, as child indexes from this part.
    private var bodies: (plain: [Int]?, html: [Int]?) {
        func find(_ part: MIMEPart, _ path: [Int]) -> (plain: [Int]?, html: [Int]?) {
            if part.isMessage { return find(part.children[0], path + [0]) }
            if part.contentType.hasPrefix("multipart/") {
                let indexed = Array(part.children.enumerated())
                if part.contentType == "multipart/alternative" {
                    var found: (plain: [Int]?, html: [Int]?) = (nil, nil)
                    for (index, child) in indexed {
                        let inner = find(child, path + [index])
                        found = (found.plain ?? inner.plain, found.html ?? inner.html)
                    }
                    return found
                }
                // Mixed, related, signed and the rest: the first part that holds a body; a forwarded
                // message only when no other part does.
                for (index, child) in indexed.filter({ !$0.element.isMessage }) + indexed.filter({ $0.element.isMessage }) {
                    let inner = find(child, path + [index])
                    if inner.plain != nil || inner.html != nil { return inner }
                }
                return (nil, nil)
            }
            guard part.disposition != "attachment" else { return (nil, nil) }
            switch part.contentType {
            case "text/plain": return (path, nil)
            case "text/html": return (nil, path)
            default: return (nil, nil)
            }
        }
        return find(self, [])
    }
}

/// A list's first words from a partial body, as an IMAP `BODY.PEEK[1]<0.2048>` or `BODY.PEEK[TEXT]<0.2048>`
/// returns it, which may stop in the middle of base64 or of a multipart.
enum MIMESnippet {
    static let limit = 200

    /// The partial decoded with its transfer encoding and charset; for the whole TEXT of a multipart
    /// message, its first plain or HTML part, past the boundaries and part headers. HTML is read as text,
    /// whitespace collapsed, at most `limit` characters.
    static func text(fromPartial data: Data, transferEncoding: String?, charset: String?, contentType: String?,
                     boundary: String?) -> String {
        var type = contentType ?? (boundary == nil ? "text/plain" : "multipart/mixed")
        if let charset { type += "; charset=\"\(charset)\"" }
        if let boundary { type += "; boundary=\"\(boundary)\"" }
        var headers = [(name: "Content-Type", value: type)]
        if let transferEncoding { headers.append((name: "Content-Transfer-Encoding", value: transferEncoding)) }
        let bytes = [UInt8](data)
        let part = MIMEMessage.entity(headers: headers, content: bytes[...], defaultType: "text/plain", depth: 0)
        if let plain = part.plainText.map(collapsed), !plain.isEmpty { return plain }
        return part.html.map { collapsed(GmailText.plainText(fromHTML: withoutCutMarkup($0))) } ?? ""
    }

    private static func collapsed(_ text: String) -> String {
        let visible = String(text.unicodeScalars.filter {
            $0.properties.generalCategory != .format && $0 != "\u{034F}"
        })
        return String(visible.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    /// HTML without what a cut leaves unreadable: a style, script or head block that never closes, a tag
    /// cut in the middle, and the invisible entities that pad a newsletter's preview text.
    private static func withoutCutMarkup(_ html: String) -> String {
        var text = html
        func remove(_ pattern: String) {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        remove("<(script|style|head)\\b[^>]*>[\\s\\S]*?</\\1\\s*>")
        remove("<(script|style|head)\\b[\\s\\S]*$")
        remove("<[^>]*$")
        remove("&(zwnj|zwj|shy|lrm|rlm);")
        return text
    }
}

/// A structured header's value and parameters: `text/plain; charset="euc-kr"`,
/// `attachment; filename*=UTF-8''%EA%B2%AC.pdf`.
struct MIMEHeaderValue {
    /// The lowercased value before the parameters.
    var value: String
    /// Parameters by lowercased name. An RFC 2231 parameter (`name*=`, `name*0*=`, `name*1=`) is joined
    /// from its sections and read in the charset its first section names, and wins over a plain one.
    var parameters: [String: String]

    init(_ header: String) {
        var segments = Self.segments(header)
        let head = segments.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        // `text/plain charset=utf-8`, a missing semicolon.
        let token = head.prefix { !$0.isWhitespace && $0 != "(" }
        let rest = head.dropFirst(token.count)
        if rest.contains("=") { segments.insert(String(rest), at: 0) }
        value = token.lowercased()

        var plain: [String: String] = [:]
        var sections: [String: [(index: Int, encoded: Bool, value: String)]] = [:]
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = Self.unquoted(segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))
            guard !key.isEmpty else { continue }
            if let star = key.firstIndex(of: "*") {
                let name = String(key[..<star])
                var suffix = key[key.index(after: star)...]
                let encoded = suffix.isEmpty || suffix.hasSuffix("*")
                if suffix.hasSuffix("*") { suffix = suffix.dropLast() }
                if !name.isEmpty, let index = suffix.isEmpty ? 0 : Int(suffix) {
                    sections[name, default: []].append((index, encoded, value))
                    continue
                }
            }
            if plain[key] == nil { plain[key] = value }
        }
        for (name, parts) in sections {
            var charset: String?
            var bytes: [UInt8] = []
            for part in parts.sorted(by: { $0.index < $1.index }) {
                guard part.encoded else {
                    bytes += Array(part.value.utf8)
                    continue
                }
                var text = Substring(part.value)
                if part.index == 0 {
                    let quotes = text.indices.filter { text[$0] == "'" }
                    if quotes.count >= 2 {
                        charset = String(text[..<quotes[0]])
                        text = text[text.index(after: quotes[1])...]
                    }
                }
                bytes += MIMETransfer.percentDecoded(Array(text.utf8)[...])
            }
            plain[name] = MIMECharset.string(Data(bytes), charset: charset.flatMap { $0.isEmpty ? nil : $0 })
        }
        parameters = plain
    }

    /// Whether `value` is a `type/subtype`.
    var isMediaType: Bool {
        let halves = value.split(separator: "/", omittingEmptySubsequences: false)
        return halves.count == 2 && !halves[0].isEmpty && !halves[1].isEmpty
    }

    /// The header split at the semicolons outside quoted strings.
    private static func segments(_ header: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                segments.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        segments.append(current)
        return segments
    }

    /// A quoted string's content, with `\"` and `\\` unescaped; other backslashes stay, as Windows paths
    /// in unescaped names need.
    private static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                if character != "\"", character != "\\" { result.append("\\") }
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

/// The header block of a message or part.
private enum MIMEHeaders {
    /// The unfolded fields, and the content after the blank line that ends them. A line that is neither a
    /// field nor a continuation starts the content, for a part that left out the blank line. Raw 8-bit
    /// values are read as UTF-8, else in the part's charset.
    static func split(_ bytes: ArraySlice<UInt8>) -> (headers: [(name: String, value: String)], content: ArraySlice<UInt8>) {
        var fields: [(name: String, value: [UInt8])] = []
        var index = bytes.startIndex
        let end = bytes.endIndex
        var contentStart = end
        while index < end {
            let lineBreak = bytes[index...].firstIndex(of: 0x0A) ?? end
            var lineEnd = lineBreak
            if lineEnd > index, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let next = lineBreak < end ? lineBreak + 1 : end
            let line = bytes[index..<lineEnd]
            if line.isEmpty {
                contentStart = next
                break
            }
            if line.first == 0x20 || line.first == 0x09, !fields.isEmpty {
                fields[fields.count - 1].value += line
            } else if let colon = line.firstIndex(of: 0x3A), let name = fieldName(line[..<colon]) {
                fields.append((name, Array(line[(colon + 1)...])))
            } else if !(index == bytes.startIndex && line.starts(with: "From ".utf8)) {
                contentStart = index
                break
            }
            index = next
        }
        var charset: String?
        if let type = fields.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            charset = MIMEHeaderValue(String(decoding: type.value, as: UTF8.self)).parameters["charset"]
        }
        let headers = fields.map { field in
            let data = Data(field.value)
            let text = String(data: data, encoding: .utf8) ?? MIMECharset.string(data, charset: charset)
            return (name: field.name, value: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (headers, bytes[contentStart..<end])
    }

    /// A field name: printable ASCII without a colon, with any spaces before the colon left out.
    private static func fieldName(_ bytes: ArraySlice<UInt8>) -> String? {
        var name = bytes
        while let last = name.last, last == 0x20 || last == 0x09 { name = name.dropLast() }
        guard !name.isEmpty, name.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }
}

/// The parts of a multipart's content.
private enum MIMEMultipart {
    /// The content between the `--boundary` lines, the line break before each belonging to the boundary.
    /// A part with no closing boundary after it runs to the end, as in a cut partial body. Without a
    /// boundary, or when the declared one is not found, the first `--` line is taken as the boundary.
    static func parts(of content: ArraySlice<UInt8>, boundary: String?) -> [ArraySlice<UInt8>] {
        if let boundary, !boundary.isEmpty {
            let found = parts(of: content, delimiter: Array(boundary.utf8))
            if !found.isEmpty { return found }
        }
        guard let guessed = firstDelimiter(in: content) else { return [] }
        return parts(of: content, delimiter: guessed)
    }

    private static func parts(of content: ArraySlice<UInt8>, delimiter boundary: [UInt8]) -> [ArraySlice<UInt8>] {
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var index = content.startIndex
        let end = content.endIndex
        while index < end {
            let lineBreak = content[index...].firstIndex(of: 0x0A) ?? end
            var lineEnd = lineBreak
            if lineEnd > index, content[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let next = lineBreak < end ? lineBreak + 1 : end
            if lineEnd - index >= boundary.count + 2, content[index] == 0x2D, content[index + 1] == 0x2D,
               content[(index + 2)..<(index + 2 + boundary.count)].elementsEqual(boundary) {
                var rest = index + 2 + boundary.count
                let closing = rest + 2 <= lineEnd && content[rest] == 0x2D && content[rest + 1] == 0x2D
                if closing { rest += 2 }
                if content[rest..<lineEnd].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let start = partStart {
                        var partEnd = index
                        if partEnd > start, content[partEnd - 1] == 0x0A { partEnd -= 1 }
                        if partEnd > start, content[partEnd - 1] == 0x0D { partEnd -= 1 }
                        parts.append(content[start..<partEnd])
                    }
                    if closing { return parts }
                    partStart = next
                }
            }
            index = next
        }
        if let start = partStart, start < end { parts.append(content[start..<end]) }
        return parts
    }

    private static func firstDelimiter(in content: ArraySlice<UInt8>) -> [UInt8]? {
        var index = content.startIndex
        while index < content.endIndex {
            let lineBreak = content[index...].firstIndex(of: 0x0A) ?? content.endIndex
            var line = content[index..<lineBreak]
            while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line = line.dropLast() }
            if line.count > 2, line.starts(with: [0x2D, 0x2D]) { return Array(line.dropFirst(2)) }
            index = lineBreak + 1
        }
        return nil
    }
}

/// Content-Transfer-Encoding and the encodings inside headers, undone on bytes.
enum MIMETransfer {
    static func decode(_ content: ArraySlice<UInt8>, encoding: String?) -> ArraySlice<UInt8> {
        let token = encoding?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            .prefix { !$0.isWhitespace && $0 != ";" && $0 != "(" }.lowercased()
        switch token {
        case "base64"?: return base64(content)[...]
        case "quoted-printable"?: return quotedPrintable(content)[...]
        default: return content
        }
    }

    /// Base64, skipping whitespace and anything outside the alphabet; missing padding is fine, and the
    /// bytes of a cut last group that are whole are kept.
    static func base64(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count / 4 * 3 + 3)
        var accumulator: UInt32 = 0
        var bits = 0
        base64Values.withUnsafeBufferPointer { values in
            for byte in input {
                let value = values[Int(byte)]
                if value < 64 {
                    accumulator = accumulator << 6 | UInt32(value)
                    bits += 6
                    if bits >= 8 {
                        bits -= 8
                        output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                    }
                } else if value == base64Padding {
                    // Padding ends a group; base64 joined after it starts a new one.
                    accumulator = 0
                    bits = 0
                }
            }
        }
        return output
    }

    /// Quoted-printable: `=XX` in either case, soft line breaks (`=` before CRLF or LF, with or without
    /// trailing spaces), and the trailing whitespace of a line dropped. An `=` that starts no escape stays;
    /// an escape cut at the end goes.
    static func quotedPrintable(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = input.startIndex
        let end = input.endIndex
        while index < end {
            let byte = input[index]
            if byte == 0x3D {
                if index + 2 < end, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                var after = index + 1
                while after < end, input[after] == 0x20 || input[after] == 0x09 { after += 1 }
                if after == end || (index + 2 == end && hexValue(input[index + 1]) != nil) {
                    index = end
                } else if input[after] == 0x0A {
                    index = after + 1
                } else if input[after] == 0x0D {
                    index = after + 1
                    if index < end, input[index] == 0x0A { index += 1 }
                } else {
                    output.append(byte)
                    index += 1
                }
            } else if byte == 0x20 || byte == 0x09 {
                var after = index
                while after < end, input[after] == 0x20 || input[after] == 0x09 { after += 1 }
                if after == end || input[after] == 0x0A || input[after] == 0x0D {
                    index = after
                } else {
                    output += input[index..<after]
                    index = after
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    /// RFC 2047's Q encoding: `_` for a space, `=XX` for a byte.
    static func qEncoding(_ input: ArraySlice<UInt8>) -> [UInt8] {
        escaped(input, marker: 0x3D, underscoreIsSpace: true)
    }

    /// RFC 2231's `%XX`.
    static func percentDecoded(_ input: ArraySlice<UInt8>) -> [UInt8] {
        escaped(input, marker: 0x25, underscoreIsSpace: false)
    }

    private static func escaped(_ input: ArraySlice<UInt8>, marker: UInt8, underscoreIsSpace: Bool) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let byte = input[index]
            if byte == marker, index + 2 < input.endIndex,
               let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                output.append(high << 4 | low)
                index += 3
                continue
            }
            output.append(underscoreIsSpace && byte == 0x5F ? 0x20 : byte)
            index += 1
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x37
        case 0x61...0x66: byte - 0x57
        default: nil
        }
    }

    private static let base64Padding: UInt8 = 65
    private static let base64Values: [UInt8] = {
        var values = [UInt8](repeating: 64, count: 256)
        for (value, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            values[Int(byte)] = UInt8(value)
        }
        values[Int(UInt8(ascii: "="))] = base64Padding
        return values
    }()
}
